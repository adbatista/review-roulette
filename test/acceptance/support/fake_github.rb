# frozen_string_literal: true

require "base64"
require "json"
require "socket"
require "uri"

# An in-process stand-in for the GitHub REST and GraphQL APIs, holding just enough
# state to observe what the roulette reads and writes.
class FakeGitHub
  TOKEN = "acceptance-token"

  attr_reader :requests, :comments, :review_requests, :assignments
  attr_accessor :viewer, :suggested_reviewers, :codeowners, :codeowners_path

  def initialize
    @mutex = Mutex.new
    @requests = []
    @comments = []
    @review_requests = []
    @assignments = []
    @viewer = "roulette-bot"
    @repositories = ["acme/mono"]
    @owners = []
    @pulls = {}
    @issues = {}
    @pending_reviews = Hash.new(0)
    @assigned_issues = []
    @suggested_reviewers = []
    @codeowners_path = ".github/CODEOWNERS"
    @teams = {}
    @next_comment_id = 100
  end

  def url = "http://127.0.0.1:#{@server.addr[1]}"

  def start
    @server = TCPServer.new("127.0.0.1", 0)
    @thread = Thread.new do
      loop { Thread.new(@server.accept) { |socket| serve(socket) } }
    rescue IOError, Errno::EBADF
      nil
    end
    self
  end

  def stop
    @server.close
    @thread.join(1)
  end

  def add_repository(slug) = @repositories << slug.downcase
  def add_owner(login) = @owners << login.downcase

  def add_pull(number, author:, labels: [], requested: [], files: [], base_ref: "main")
    @pulls[number] = { author:, labels:, requested: requested.dup, files:, base_ref: }
  end

  def add_issue(number, author:, labels: [], assignees: [])
    @issues[number] = { author:, labels:, assignees: assignees.dup }
  end

  def pending_reviews(counts) = counts.each { |login, count| @pending_reviews[login.to_s.downcase] = count }

  # Each project is a hash of field name to value, e.g. { "Status" => "In progress" }.
  def assign_issue(login, repo:, projects: [])
    @assigned_issues << { login: login.downcase, repo: repo.downcase, projects: }
  end

  def add_team(slug, members) = @teams[slug.downcase] = members

  def add_comment(body, author: viewer, type: "User")
    @comments << { id: (@next_comment_id += 1), body:, user: { login: author, type: } }
    @comments.last
  end

  def writes = requests.reject { |request| request[:method] == "GET" || request[:path] == "/graphql" }

  private

  def serve(socket)
    request_line = socket.gets or return
    method, target, = request_line.split
    headers = {}
    while (line = socket.gets) && line != "\r\n"
      name, value = line.split(":", 2)
      headers[name.downcase] = value.strip
    end
    body = headers["content-length"] ? socket.read(headers["content-length"].to_i) : ""
    status, payload = @mutex.synchronize { handle(method, URI(target), body, headers) }
    json = JSON.generate(payload)
    socket.write("HTTP/1.1 #{status} Fake\r\nContent-Type: application/json\r\n" \
                 "Content-Length: #{json.bytesize}\r\nConnection: close\r\n\r\n#{json}")
  rescue StandardError => e
    warn "FakeGitHub error: #{e.full_message}"
  ensure
    socket.close
  end

  def handle(method, uri, body, headers)
    path = URI.decode_www_form_component(uri.path)
    data = body.empty? ? {} : JSON.parse(body)
    @requests << { method:, path:, body: data }
    return [401, { message: "Bad credentials" }] unless headers["authorization"].to_s.end_with?(TOKEN)
    return [200, { data: graphql(data["query"], data["variables"] || {}) }] if path == "/graphql"

    rest(method, path, data) || [404, { message: "Not Found" }]
  end

  def graphql(query, variables)
    if query.include?("suggestedReviewers")
      suggestions = suggested_reviewers.map { |login| { reviewer: { login: } } }
      { repository: { pullRequest: { suggestedReviewers: suggestions } } }
    elsif query.include?("viewer {")
      { repository: repository_node(variables), viewer: { login: viewer } }
    elsif query.include?("organization(")
      { organization: owner_node(variables["login"]) }
    elsif query.include?("repositoryOwner(")
      { repositoryOwner: owner_node(variables["login"]) }
    elsif query.include?("projectItems")
      { search: { pageInfo: { hasNextPage: false, endCursor: nil },
                  nodes: issues_matching(variables["q"]).map { |issue| issue_node(issue, variables["field"]) } } }
    elsif query.include?("issueCount")
      variables.to_h { |name, search| [name, { issueCount: count(search) }] }
    else
      { repository: repository_node(variables) }
    end
  end

  def repository_node(variables)
    slug = "#{variables['owner']}/#{variables['repo']}"
    @repositories.include?(slug.downcase) ? { nameWithOwner: slug } : nil
  end

  def owner_node(login) = @owners.include?(login.downcase) ? { login: } : nil

  def count(search)
    reviewer = search[/review-requested:(\S+)/, 1]
    reviewer ? @pending_reviews[reviewer.downcase] : issues_matching(search).size
  end

  def issues_matching(search)
    login = search[/assignee:(\S+)/, 1].downcase
    repo = search[/repo:(\S+)/, 1]&.downcase
    org = search[/org:(\S+)/, 1]&.downcase
    @assigned_issues.select do |issue|
      issue[:login] == login && (repo ? issue[:repo] == repo : issue[:repo].start_with?("#{org}/"))
    end
  end

  def issue_node(issue, field)
    items = issue[:projects].map do |project|
      { isArchived: false, fieldValueByName: project[field] ? { name: project[field] } : nil }
    end
    { projectItems: { nodes: items } }
  end

  def rest(method, path, data)
    case [method, path]
    in ["GET", %r{\A/repos/acme/mono/pulls/(\d+)\z}]
      pull = @pulls[$1.to_i] or return
      [200, { user: { login: pull[:author] }, labels: labels(pull), base: { ref: pull[:base_ref] } }]
    in ["GET", %r{\A/repos/acme/mono/pulls/(\d+)/requested_reviewers\z}]
      [200, { users: @pulls.fetch($1.to_i)[:requested].map { |login| { login: } }, teams: [] }]
    in ["POST", %r{\A/repos/acme/mono/pulls/(\d+)/requested_reviewers\z}]
      @review_requests.concat(data["reviewers"])
      @pulls.fetch($1.to_i)[:requested].concat(data["reviewers"])
      [201, {}]
    in ["GET", %r{\A/repos/acme/mono/pulls/(\d+)/files\z}]
      [200, @pulls.fetch($1.to_i)[:files].map { |filename| { filename: } }]
    in ["GET", %r{\A/repos/acme/mono/issues/(\d+)\z}]
      issue = @issues[$1.to_i] or return
      [200, { user: { login: issue[:author] }, labels: labels(issue),
              assignees: issue[:assignees].map { |login| { login: } } }]
    in ["POST", %r{\A/repos/acme/mono/issues/(\d+)/assignees\z}]
      @assignments.concat(data["assignees"])
      issue = @issues.fetch($1.to_i)
      issue[:assignees].concat(data["assignees"])
      [201, { assignees: issue[:assignees].map { |login| { login: } } }]
    in ["GET", %r{\A/repos/acme/mono/issues/\d+/comments\z}]
      [200, @comments]
    in ["POST", %r{\A/repos/acme/mono/issues/\d+/comments\z}]
      [201, add_comment(data["body"])]
    in ["PATCH", %r{\A/repos/acme/mono/issues/comments/(\d+)\z}]
      comment = @comments.find { |candidate| candidate[:id] == $1.to_i } or return
      comment[:body] = data["body"]
      [200, comment]
    in ["GET", %r{\A/repos/acme/mono/contents/(.+)\z}]
      return unless codeowners && $1 == codeowners_path

      [200, { type: "file", content: Base64.encode64(codeowners) }]
    in ["GET", %r{\A/orgs/acme/teams/([^/]+)/members\z}]
      members = @teams[$1.downcase] or return
      [200, members.map { |login| { login: } }]
    else
      nil
    end
  end

  def labels(target) = target[:labels].map { |name| { name: } }
end
