# frozen_string_literal: true

require "base64"
require "erb"
require "json"
require "net/http"
require "time"
require "uri"

module ReviewRoulette
  class ApiError < Error
    attr_reader :status, :headers

    def initialize(message, status: nil, headers: {})
      super(message)
      @status = status
      @headers = headers
    end
  end

  Snapshot = Struct.new(:author, :requested_reviewers, :labels, :base_ref, keyword_init: true)
  Response = Struct.new(:status, :headers, :body)

  class NetTransport
    NETWORK_ERRORS = [SystemCallError, SocketError, Timeout::Error, OpenSSL::SSL::SSLError, EOFError].freeze

    def call(method, uri, headers, body)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 10
      http.read_timeout = 30
      response = http.send_request(method, uri.request_uri, body, headers)
      Response.new(response.code.to_i, response.to_hash.transform_values(&:first), response.body.to_s)
    rescue *NETWORK_ERRORS => e
      raise Error, "Could not reach the GitHub API (#{e.class})"
    end
  end

  class GitHub
    BATCH = 20
    MAX_ATTEMPTS = 3
    WAIT_BUDGET = 30
    CODEOWNERS_PATHS = [".github/CODEOWNERS", "CODEOWNERS", "docs/CODEOWNERS"].freeze
    ISSUE_LOAD_QUERY = <<~GRAPHQL.gsub(/\s+/, " ").strip
      query($q: String!, $field: String!, $after: String) {
        search(type: ISSUE, first: 100, query: $q, after: $after) {
          pageInfo { hasNextPage endCursor }
          nodes { ... on Issue { projectItems(first: 20) { nodes {
            isArchived fieldValueByName(name: $field) { ... on ProjectV2ItemFieldSingleSelectValue { name } }
          } } } }
        }
      }
    GRAPHQL

    def initialize(token, env: ENV, transport: NetTransport.new, sleeper: ->(seconds) { sleep(seconds) },
                   clock: -> { Time.now.to_f })
      @token = token
      @api = (env["GITHUB_API_URL"] || "https://api.github.com").chomp("/")
      @graphql = env["GITHUB_GRAPHQL_URL"] || "#{@api.sub(%r{/v3\z}, '')}/graphql"
      @transport = transport
      @sleeper = sleeper
      @clock = clock
    end

    # Returns the login the token acts as, after confirming every configured scope is visible.
    def check_access(target, organizations, issue_scopes = [])
      data = graphql("query($owner: String!, $repo: String!) { repository(owner: $owner, name: $repo) " \
                     "{ nameWithOwner } viewer { login } }", owner: target.owner, repo: target.repo)
      unless data.dig("repository", "nameWithOwner").to_s.casecmp?("#{target.owner}/#{target.repo}")
        raise Error, "Target repository is inaccessible or mismatched"
      end

      login = data.dig("viewer", "login") or raise Error, "Cannot resolve authenticated comment identity"
      ReviewRoulette.unique(organizations).each { |organization| check_organization(organization) }
      ReviewRoulette.unique(issue_scopes).each { |scope| check_issue_scope(scope) }
      login
    end

    def pull(target)
      pull = get("#{repo_path(target)}/pulls/#{target.number}")
      requested = pages("#{repo_path(target)}/pulls/#{target.number}/requested_reviewers")
                  .flat_map { |page| page.fetch("users").map { |user| user.fetch("login") } }
      Snapshot.new(author: pull.fetch("user").fetch("login"), requested_reviewers: requested,
                   labels: pull.fetch("labels").map { |label| label.fetch("name") },
                   base_ref: pull.fetch("base").fetch("ref"))
    end

    def issue(target)
      issue = get("#{repo_path(target)}/issues/#{target.number}")
      Snapshot.new(author: issue.dig("user", "login").to_s,
                   requested_reviewers: (issue["assignees"] || []).map { |assignee| assignee.fetch("login") },
                   labels: issue.fetch("labels").map { |label| label.is_a?(String) ? label : label["name"].to_s },
                   base_ref: "")
    end

    def files(target)
      pages("#{repo_path(target)}/pulls/#{target.number}/files").flatten.map { |file| file.fetch("filename") }
    end

    def codeowners(target, ref)
      CODEOWNERS_PATHS.each do |path|
        content = get("#{repo_path(target)}/contents/#{path}?ref=#{escape(ref)}")
        return Base64.decode64(content.fetch("content")).force_encoding(Encoding::UTF_8) if file?(content)
      rescue ApiError => e
        raise unless e.status == 404
      end
      nil
    end

    def team_members(organization, team)
      pages("/orgs/#{escape(organization)}/teams/#{escape(team)}/members").flatten.map { |user| user.fetch("login") }
    rescue ApiError => e
      raise unless e.status == 404

      raise Error, "A CODEOWNERS team is inaccessible; the token needs to read its members"
    end

    def suggested_reviewers(target)
      data = graphql("query($owner: String!, $repo: String!, $number: Int!) { repository(owner: $owner, " \
                     "name: $repo) { pullRequest(number: $number) { suggestedReviewers { reviewer { login } } } } }",
                     owner: target.owner, repo: target.repo, number: target.number)
      suggestions = data.dig("repository", "pullRequest", "suggestedReviewers") or
        raise Error, "Cannot resolve suggested reviewers for the target PR"
      ReviewRoulette.unique(suggestions.map { |suggestion| suggestion.fetch("reviewer").fetch("login") })
    end

    # Pending review requests per lower-cased login, summed across organizations when given.
    def review_counts(target, organizations, reviewers)
      scopes = organizations.empty? ? ["repo:#{target.owner}/#{target.repo}"] : unique_scopes(organizations, "org")
      count_searches(searches(reviewers, scopes) { |scope, login| "is:pr is:open #{scope} review-requested:#{login}" })
    end

    def issue_loads(scopes, reviewers, status_field, weights)
      qualified = ReviewRoulette.unique(scopes).map { |scope| "#{scope.include?('/') ? 'repo' : 'org'}:#{scope}" }
      found = searches(reviewers, qualified) { |scope, login| "is:issue is:open #{scope} assignee:#{login}" }
      return count_searches(found) if weights.empty?

      fallback = weights.fetch("*", 1)
      found.each_with_object(Hash.new(0)) do |(login, query), loads|
        loads[login] += each_issue(query, status_field).sum { |issue| issue_weight(issue, weights, fallback) }
      end
    end

    def comments(target)
      pages("#{repo_path(target)}/issues/#{target.number}/comments").flatten.map do |comment|
        { id: comment.fetch("id"), body: comment["body"].to_s, author: comment.dig("user", "login").to_s,
          type: comment.dig("user", "type").to_s }
      end
    end

    def request_review(target, reviewer)
      write("POST", "#{repo_path(target)}/pulls/#{target.number}/requested_reviewers", reviewers: [reviewer])
    end

    def assign_issue(target, assignee)
      issue = write("POST", "#{repo_path(target)}/issues/#{target.number}/assignees", assignees: [assignee])
      # GitHub answers 201 but drops users who cannot be assigned in this repository.
      return if (issue["assignees"] || []).any? { |user| user["login"].to_s.casecmp?(assignee) }

      raise Error, "GitHub did not assign the selected user to the issue"
    end

    def create_comment(target, body)
      write("POST", "#{repo_path(target)}/issues/#{target.number}/comments", body:)
    end

    def update_comment(target, id, body)
      write("PATCH", "#{repo_path(target)}/issues/comments/#{id}", body:)
    end

    private

    def repo_path(target) = "/repos/#{target.owner}/#{target.repo}"
    def escape(text) = ERB::Util.url_encode(text)
    def file?(content) = content.is_a?(Hash) && content["type"] == "file"
    def unique_scopes(names, qualifier) = ReviewRoulette.unique(names).map { |name| "#{qualifier}:#{name}" }

    def check_organization(login)
      data = graphql("query($login: String!) { organization(login: $login) { login } }", login:)
      return if data.dig("organization", "login").to_s.casecmp?(login)

      raise Error, "Configured organization is inaccessible or mismatched"
    end

    def check_issue_scope(scope)
      owner, repo = scope.split("/")
      found = if repo
                graphql("query($owner: String!, $repo: String!) { repository(owner: $owner, name: $repo) " \
                        "{ nameWithOwner } }", owner:, repo:).dig("repository", "nameWithOwner")
              else
                graphql("query($login: String!) { repositoryOwner(login: $login) { login } }", login: owner)
                  .dig("repositoryOwner", "login")
              end
      raise Error, "Configured issue repository is inaccessible or mismatched" unless found.to_s.casecmp?(scope)
    end

    def searches(reviewers, scopes)
      ReviewRoulette.unique(reviewers).flat_map do |login|
        scopes.map { |scope| [login.downcase, yield(scope, login)] }
      end
    end

    def count_searches(found)
      counts = found.to_h { |login, _| [login, 0] }
      found.each_slice(BATCH) do |batch|
        declarations = batch.each_index.map { |index| "$q#{index}: String!" }.join(", ")
        fields = batch.each_index.map do |index|
          "q#{index}: search(type: ISSUE, first: 1, query: $q#{index}) { issueCount }"
        end
        variables = batch.each_with_index.to_h { |(_, query), index| ["q#{index}", query] }
        result = graphql("query(#{declarations}) { #{fields.join("\n")} }", variables)
        batch.each_with_index do |(login, _), index|
          count = result.dig("q#{index}", "issueCount")
          unless count.is_a?(Integer) && !count.negative?
            raise Error, "GitHub returned a missing or invalid workload count"
          end

          counts[login] += count
        end
      end
      counts
    end

    def each_issue(query, status_field)
      issues = []
      after = nil
      loop do
        search = graphql(ISSUE_LOAD_QUERY, q: query, field: status_field, after:)["search"]
        unless search.is_a?(Hash) && search["nodes"].is_a?(Array) && search["pageInfo"].is_a?(Hash)
          raise Error, "GitHub returned a missing or invalid issue workload"
        end

        issues.concat(search["nodes"])
        after = search["pageInfo"]["hasNextPage"] && search["pageInfo"]["endCursor"]
        return issues unless after
      end
    end

    def issue_weight(issue, weights, fallback)
      items = issue.is_a?(Hash) ? issue.dig("projectItems", "nodes") || [] : []
      statuses = items.filter_map do |item|
        name = item && !item["isArchived"] && item.dig("fieldValueByName", "name")
        weights.fetch(name.downcase, fallback) if name
      end
      statuses.max || fallback
    end

    def graphql(query, variables)
      body = retrying { request("POST", URI(@graphql), query:, variables:) }
      raise ApiError, body["errors"].first["message"].to_s if body["errors"].is_a?(Array) && body["errors"].any?

      body["data"] || {}
    end

    def get(path) = retrying { request("GET", URI("#{@api}#{path}")) }

    # A server error can follow a successful write, so ambiguous write failures are not retried.
    def write(method, path, payload) = retrying(read: false) { request(method, URI("#{@api}#{path}"), payload) }

    def pages(path)
      uri = URI("#{@api}#{path}")
      uri.query = [uri.query, "per_page=100"].compact.join("&")
      found = []
      while uri
        response = retrying { perform("GET", uri) }
        found << parse(response)
        uri = next_page(response, uri)
      end
      found
    end

    def next_page(response, current)
      link = response.headers["link"].to_s[/<([^>]+)>;\s*rel="next"/, 1] or return
      following = URI(link)
      # The token must never follow a link to another host.
      [following.scheme, following.host, following.port] == [current.scheme, current.host, current.port] or
        raise Error, "GitHub returned a pagination link to an unexpected host"
      following
    end

    def request(method, uri, payload = nil) = parse(perform(method, uri, payload))

    def perform(method, uri, payload = nil)
      headers = { "Authorization" => "Bearer #{@token}", "Accept" => "application/vnd.github+json",
                  "User-Agent" => "review-roulette/#{VERSION}", "X-GitHub-Api-Version" => "2022-11-28" }
      headers["Content-Type"] = "application/json" if payload
      response = @transport.call(method, uri, headers, payload && JSON.generate(payload))
      return response if response.status.between?(200, 299)

      message = parse(response)["message"] if response.body.start_with?("{")
      raise ApiError.new(message || "GitHub API request failed with status #{response.status}",
                         status: response.status, headers: response.headers.transform_keys(&:downcase))
    end

    def parse(response)
      response.body.empty? ? {} : JSON.parse(response.body)
    rescue JSON::ParserError
      raise Error, "GitHub returned a response that is not JSON"
    end

    def retrying(read: true)
      waited = 0
      attempt = 0
      begin
        yield
      rescue ApiError => e
        delay = retry_delay(e, attempt, read)
        raise if delay.nil? || waited + delay > WAIT_BUDGET

        waited += delay
        attempt += 1
        @sleeper.call(delay)
        retry
      end
    end

    def retry_delay(error, attempt, read)
      headers = error.headers
      return if attempt >= MAX_ATTEMPTS - 1 || !retryable?(error, read)

      delay = if headers.key?("retry-after") then retry_after(headers["retry-after"])
              elsif exhausted?(headers) && headers["x-ratelimit-reset"]
                Float(headers["x-ratelimit-reset"], exception: false)&.-(@clock.call)&.+(1)
              else
                2**attempt
              end
      delay && [1, delay].max
    end

    def exhausted?(headers) = headers["x-ratelimit-remaining"] == "0"

    def retryable?(error, read)
      return true if error.status == 429
      return true if error.status == 403 && (error.headers.key?("retry-after") || exhausted?(error.headers))

      read && !error.status.nil? && error.status >= 500
    end

    def retry_after(value)
      Float(value, exception: false) || (Time.httpdate(value).to_f - @clock.call)
    rescue ArgumentError
      nil
    end
  end
end
