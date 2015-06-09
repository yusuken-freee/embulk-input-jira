require "embulk/input/jira_input_plugin_utils"
require "embulk/input/jira/api"
require "logger"
require "time"

module Embulk
  module Input
    class JiraInputPlugin < InputPlugin
      PER_PAGE = 50

      Plugin.register_input("jira", self)

      def self.transaction(config, &control)
        task = {
          "username" => config.param("username", :string),
          "password" => config.param("password", :string),
          "uri" => config.param("uri", :string),
          "jql" => config.param("jql", :string),
        }

        attributes = {}
        columns = config.param("columns", :array).map do |column|
          name = column["name"]
          type = column["type"].to_sym
          attributes[name] = type
          Column.new(nil, name, type, column["format"])
        end

        task["attributes"] = attributes

        resume(task, columns, 1, &control)
      end

      def self.resume(task, columns, count, &control)
        commit_reports = yield(task, columns, count)

        next_config_diff = {}
        return next_config_diff
      end

      def self.guess(config)
        # TODO: api_version should be 2 (the latest version)
        # auth_type should be specified from config. (The future task)

        username = config.param("username", :string)
        password = config.param("password", :string)
        uri = config.param("uri", :string)
        api_version = "latest"
        auth_type = "basic"
        jql = config.param("jql", :string)

        jira = Jira::Api.setup do |jira_config|
          jira_config.username = username
          jira_config.password = password
          jira_config.uri = uri
          jira_config.api_version = api_version
          jira_config.auth_type = auth_type
        end

        # TODO: we use 0..10 issues to guess config?
        records = jira.search_issues(jql)[0..10].map do |issue|
          issue.to_record
        end

        columns = JiraInputPluginUtils.guess_columns(records)

        guessed_config = {
          "columns" => columns,
        }

        return guessed_config
      end

      def init
        @attributes = task["attributes"]
        @jira = Jira::Api.setup do |config|
          config.username = task["username"]
          config.password = task["password"]
          config.uri = task["uri"]
          config.api_version = "latest"
          config.auth_type = :basic
        end
        @jql = task["jql"]
      end

      def run
        total_count = @jira.total_count(@jql)
        last_page = (total_count.to_f / PER_PAGE).ceil

        0.step(total_count, PER_PAGE).with_index(1) do |start_at, page|
          logger.debug "Fetching #{page} / #{last_page} page"
          @jira.search_issues(@jql, start_at: start_at).each do |issue|
            values = @attributes.map do |(attribute_name, type)|
              JiraInputPluginUtils.cast(issue[attribute_name], type)
            end

            page_builder.add(values)
          end
        end

        page_builder.finish

        commit_report = {}
        return commit_report
      end

      def self.logger
        @logger ||=
          begin
            logger = Logger.new($stdout)
            logger.formatter = proc do |severity, datetime, progname, msg|
              "#{datetime.strftime("%Y-%m-%d %H:%M:%S.%L %z")} [#{severity}] #{msg}\n"
            end
            logger
          end
      end

      def logger
        self.class.logger
      end
    end
  end
end