# frozen_string_literal: true
# executes a deploy and writes log to job output
# finishes when cluster is "Ready"
require 'vault'

module Kubernetes
  class DeployExecutor
    WAIT_FOR_LIVE = ENV.fetch('KUBE_WAIT_FOR_LIVE', 10).to_i.minutes
    STABILITY_CHECK_DURATION = 1.minute
    TICK = 2.seconds
    RESTARTED = "Restarted"

    # TODO: this logic might be able to go directly into Pod, which would simplify the code here a bit
    class ReleaseStatus
      attr_reader :live, :stop, :details, :pod, :role, :group
      def initialize(stop: false, live:, details:, pod:, role:, group:)
        @live = live
        @stop = stop
        @details = details
        @pod = pod
        @role = role
        @group = group
      end
    end

    def initialize(output, job:, reference:)
      @output = output
      @job = job
      @reference = reference
      @build_finder = Samson::BuildFinder.new(
        @output,
        @job,
        @reference,
        build_selectors: build_selectors
      )
    end

    # here to make restart_signal_handler happy
    def pid
      "Kubernetes-deploy-#{object_id}"
    end

    # here to make restart_signal_handler happy
    def pgid
      pid
    end

    def cancel(_signal)
      @build_finder.cancelled!
      @cancelled = true
    end

    def execute(*)
      verify_kubernetes_templates!
      @builds = @build_finder.ensure_successful_builds
      return false if cancelled?
      @release = create_release

      prerequisites, deploys = @release.release_docs.partition(&:prerequisite?)
      if prerequisites.any?
        @output.puts "First deploying prerequisite ..." if deploys.any?
        return false unless deploy_and_watch(prerequisites)
        @output.puts "Now deploying other roles ..." if deploys.any?
      end
      if deploys.any?
        return false unless deploy_and_watch(deploys)
      end
      true
    end

    private

    # check all pods and see if they are running
    # once they are running check if they are stable (for apps only, since jobs are finished and will not change)
    def wait_for_resources_to_complete(release_docs)
      raise "prerequisites should not check for stability" if @testing_for_stability
      @wait_start_time = Time.now
      @output.puts "Waiting for pods to be created"

      loop do
        statuses = pod_statuses(release_docs)
        if statuses.none?
          @output.puts "No pods were created"
          return success
        end
        not_ready = statuses.reject(&:live)

        if @testing_for_stability
          if not_ready.any?
            print_statuses(statuses)
            unstable!('one or more pods are not live', not_ready)
            return statuses
          else
            @output.puts "Testing for stability: #{stable_time_remaining}s"
            return success if stable?
          end
        else
          print_statuses(statuses)
          if not_ready.any?
            if stopped = not_ready.select(&:stop).presence
              unstable!('one or more pods stopped', stopped)
              return statuses
            elsif seconds_waiting > WAIT_FOR_LIVE
              @output.puts "TIMEOUT, pods took too long to get live"
              return statuses
            end
          elsif statuses.all? { |s| s.pod.completed? }
            return success
          else
            @output.puts "READY, starting stability test"
            @testing_for_stability = Time.now.to_i
          end
        end

        sleep TICK
        return statuses if cancelled?
      end
    end

    def stable?
      stable_time_remaining == 0
    end

    def stable_time_remaining
      [@testing_for_stability + STABILITY_CHECK_DURATION - Time.now.to_i, 0].max
    end

    def pod_statuses(release_docs)
      pods = fetch_pods
      release_docs.flat_map { |release_doc| release_statuses(pods, release_doc) }
    end

    # efficient pod fetching by querying once per cluster instead of once per deploy group
    def fetch_pods
      @release.clients.flat_map do |client, query|
        pods = SamsonKubernetes.retry_on_connection_errors { client.get_pods(query).fetch(:items) }
        pods.map! { |p| Kubernetes::Api::Pod.new(p, client: client) }
      end
    end

    def show_failure_cause(release_docs, statuses)
      release_docs.each { |doc| print_resource_events(doc) }
      log_end_time = Integer(ENV['KUBERNETES_LOG_TIMEOUT'] || '20').seconds.from_now
      debug_pods = statuses.reject(&:live).select(&:pod).group_by(&:role).map { |_, g| g.first.pod }
      debug_pods.each do |pod|
        @output.puts "\n#{pod_identifier(pod)}:"
        print_pod_events(pod)
        @output.puts
        print_pod_logs(pod, log_end_time)
        @output.puts "\n------------------------------------------\n"
      end
    rescue
      info = ErrorNotifier.notify($!, sync: true)
      @output.puts "Error showing failure cause: #{info}"
    end

    def pod_identifier(pod)
      "#{deploy_group_for_pod(pod).name} pod #{pod.name}"
    end

    # show why container failed to boot
    def print_pod_logs(pod, end_time)
      @output.puts "LOGS:"

      containers = (pod.containers + pod.init_containers).map { |c| c.fetch(:name) }
      containers.each do |container|
        @output.puts "Container #{container}" if containers.size > 1

        # Display the first and last n_lines of the log
        max = Integer(ENV['KUBERNETES_LOG_LINES'] || '50')
        lines = (pod.logs(container, end_time) || "No logs found").split("\n")
        lines = lines.first(max / 2) + ['...'] + lines.last(max / 2) if lines.size > max
        lines.each { |line| @output.puts "  #{line}" }
      end
    end

    # show what happened at the resource level ... need uid to avoid showing previous events
    def print_resource_events(doc)
      doc.resources.each do |resource|
        selector = ["involvedObject.name=#{resource.name}"]

        # do not query for nil uid ... rather show events for old+new resource when creation failed
        if uid = resource.uid
          selector << "involvedObject.uid=#{uid}"
        end

        events = doc.deploy_group.kubernetes_cluster.client.get_events(
          namespace: resource.namespace,
          field_selector: selector.join(',')
        ).fetch(:items)
        next if events.none?
        @output.puts "RESOURCE EVENTS #{resource.namespace}.#{resource.name}:"
        print_events(events)
      end
    end

    # show what happened in kubernetes internally since we might not have any logs
    def print_pod_events(pod)
      @output.puts "POD EVENTS:"
      print_events(pod.events)
    end

    def print_events(events)
      groups = events.group_by { |e| [e[:reason], (e[:message] || "").split("\n").sort] }
      groups.each do |_, event_group|
        count = event_group.sum { |e| e[:count] }
        counter = " x#{count}" if count != 1
        e = event_group.first
        @output.puts "  #{e[:reason]}: #{e[:message]}#{counter}"
      end
    end

    def unstable!(reason, bad_release_statuses)
      @output.puts "UNSTABLE: #{reason}"
      bad_release_statuses.select(&:pod).each do |status|
        @output.puts "  #{pod_identifier(status.pod)}: #{status.details}"
      end
    end

    # user clicked cancel button in UI
    def cancelled?
      if @cancelled
        @output.puts "CANCELLED"
        true
      end
    end

    def release_statuses(pods, release_doc)
      group = release_doc.deploy_group
      role = release_doc.kubernetes_role

      pods = pods.select { |pod| pod.role_id == role.id && pod.deploy_group_id == group.id }

      statuses = Array.new(release_doc.desired_pod_count).each_with_index.map do |_, i|
        pod = pods[i]

        status = if !pod
          {live: false, details: "Missing", pod: pod}
        elsif pod.restarted?
          {live: false, stop: true, details: "Restarted", pod: pod}
        elsif pod.failed?
          {live: false, stop: true, details: "Failed", pod: pod}
        elsif release_doc.prerequisite? ? pod.completed? : pod.live?
          {live: true, details: "Live", pod: pod}
        elsif pod.events_indicate_failure?
          {live: false, stop: true, details: "Error", pod: pod}
        else
          {live: false, details: "Waiting (#{pod.phase}, #{pod.reason})", pod: pod}
        end

        status[:details] += " (autoscaled role, only showing one pod)" if role.autoscaled?
        status
      end

      # If a role is autoscaled, there is a chance pods can be deleted during a deployment.
      # Sort them by "most alive" and use the first one, so we ensure at least one pods works.
      statuses.sort_by!(&method(:pod_liveliness)).slice!(1..-1) if role.autoscaled?

      statuses.map do |status|
        ReleaseStatus.new(status.merge(role: role.name, group: group.name))
      end
    end

    def pod_liveliness(status_hash)
      if status_hash[:live]
        -1
      elsif status_hash[:stop]
        1
      else
        0
      end
    end

    def print_statuses(status_groups)
      return if @last_status_output && @last_status_output > 10.seconds.ago

      @last_status_output = Time.now
      @output.puts "Deploy status after #{seconds_waiting} seconds:"
      status_groups.group_by(&:group).each do |group, statuses|
        statuses.each do |status|
          @output.puts "  #{group} #{status.role}: #{status.details}"
        end
      end
    end

    def rollback(release_docs)
      release_docs.each do |release_doc|
        begin
          if release_doc.blue_green_color
            # NOTE: service is not rolled back since it was not changed during deploy
            delete_blue_green_resources(release_doc)
          else
            puts_action(release_doc.previous_resources.any? ? 'Rolling back' : 'Deleting', release_doc)
            release_doc.revert
          end
        rescue # ... still show events and logs if somehow the rollback fails
          @output.puts "FAILED: #{$!.message}"
        end
      end
    end

    def puts_action(action, release_doc)
      blue_green = " #{release_doc.blue_green_color.upcase} resources for" if release_doc.blue_green_color
      @output.puts "#{action}#{blue_green} #{release_doc.deploy_group.name} role #{release_doc.kubernetes_role.name}"
    end

    # create a release, storing all the configuration
    def create_release
      release = Kubernetes::Release.create_release(
        builds: @builds,
        deploy: @job.deploy,
        grouped_deploy_group_roles: grouped_deploy_group_roles,
        git_sha: @job.commit,
        git_ref: @reference,
        user: @job.user,
        project: @job.project
      )

      unless release.persisted?
        raise Samson::Hooks::UserError, "Failed to create release: #{release.errors.full_messages.inspect}"
      end

      @output.puts("Created kubernetes release #{release.url}")
      release
    end

    def grouped_deploy_group_roles
      @grouped_deploy_group_roles ||= begin
        deploy_group_roles = Kubernetes::DeployGroupRole.where(
          project_id: @job.project_id,
          deploy_group: @job.deploy.stage.deploy_groups.map(&:id)
        )

        # roles that exist in the repo for this sha
        roles_present_in_repo = Kubernetes::Role.configured_for_project(@job.project, @job.commit)

        # check that all roles have a matching deploy_group_role
        # and all roles are configured
        errors = []
        groups = @job.deploy.stage.deploy_groups.map do |deploy_group|
          group_roles = deploy_group_roles.select { |dgr| dgr.deploy_group_id == deploy_group.id }

          # safe some sql queries during release creation
          group_roles.each do |dgr|
            dgr.deploy_group = deploy_group
            found = roles_present_in_repo.detect { |r| r.id == dgr.kubernetes_role_id }
            dgr.kubernetes_role = found if found
          end

          if missing = (group_roles.map(&:kubernetes_role) - roles_present_in_repo).presence
            files = missing.map(&:config_file).sort
            raise(
              Samson::Hooks::UserError,
              "Could not find config files for #{deploy_group.name} #{files.join(", ")} at #{@job.commit}"
            )
          end

          if extra = (roles_present_in_repo - group_roles.map(&:kubernetes_role)).presence
            roles = extra.map(&:name).join(', ')
            raise(
              Samson::Hooks::UserError,
              "Role #{roles} for #{deploy_group.name} is not configured, but in repo at #{@job.commit}. " \
              "Remove it from the repo or configure it via the stage page."
            )
          end

          group_roles
        end

        raise Samson::Hooks::UserError, errors.join("\n") if errors.any?
        groups
      end
    end

    # updates resources via kubernetes api
    def deploy(release_docs)
      # We deploy each resource in parallel.
      resources = release_docs.flat_map do |release_doc|
        puts_action "Deploying", release_doc

        if release_doc.blue_green_color
          non_service_resources(release_doc)
        else
          release_doc.deploy_group.kubernetes_cluster # cache before threading
          [release_doc]
        end
      end
      Samson::Parallelizer.map(resources, db: true, &:deploy)
    end

    def deploy_and_watch(release_docs)
      deploy(release_docs)
      result = wait_for_resources_to_complete(release_docs)
      if result == true
        if blue_green = release_docs.select(&:blue_green_color).presence
          finish_blue_green_deployment(blue_green)
        end
        true
      else
        show_failure_cause(release_docs, result)
        rollback(release_docs) if @job.deploy.kubernetes_rollback
        @output.puts "DONE"
        false
      end
    end

    def success
      @output.puts "SUCCESS"
      true
    end

    def seconds_waiting
      (Time.now - @wait_start_time).to_i if @wait_start_time
    end

    # find deploy group without extra sql queries
    def deploy_group_for_pod(pod)
      @release.release_docs.detect { |rd| break rd.deploy_group if rd.deploy_group_id == pod.deploy_group_id }
    end

    # vary by role and not by deploy-group
    def build_selectors
      temp_release_docs.uniq(&:kubernetes_role_id).flat_map(&:build_selectors).uniq
    end

    # verify with a temp release so we can verify everything before creating a real release
    # and having to wait for docker build to finish
    def verify_kubernetes_templates!
      # - make sure each file exists
      # - make sure each deploy group has consistent labels
      grouped_deploy_group_roles.each do |deploy_group_roles|
        element_groups = deploy_group_roles.map do |deploy_group_role|
          role = deploy_group_role.kubernetes_role
          config = role.role_config_file(@job.commit)
          raise Samson::Hooks::UserError, "Error parsing #{role.config_file}" unless config
          config.elements
        end.compact
        Kubernetes::RoleValidator.validate_groups(element_groups)
      end

      # make sure each template is valid
      temp_release_docs.each(&:verify_template)
    end

    def temp_release_docs
      @temp_release_docs ||= begin
        release = Kubernetes::Release.new(
          project: @job.project,
          git_sha: @job.commit,
          git_ref: 'master',
          deploy: @job.deploy
        )
        grouped_deploy_group_roles.flatten.map do |deploy_group_role|
          Kubernetes::ReleaseDoc.new(
            kubernetes_release: release,
            deploy_group: deploy_group_role.deploy_group,
            kubernetes_role: deploy_group_role.kubernetes_role
          )
        end
      end
    end

    def finish_blue_green_deployment(release_docs)
      switch_blue_green_service(release_docs)
      previous = @release.previous_successful_release
      if previous && previous.blue_green_color != @release.blue_green_color
        previous.release_docs.each { |d| delete_blue_green_resources(d) }
      end
    end

    def switch_blue_green_service(release_docs)
      release_docs.each do |release_doc|
        next unless services = service_resources(release_doc).presence
        @output.puts "Switching service for #{release_doc.deploy_group.name} " \
          "role #{release_doc.kubernetes_role.name} to #{release_doc.blue_green_color.upcase}"
        services.each(&:deploy)
      end
    end

    def delete_blue_green_resources(release_doc)
      puts_action "Deleting", release_doc
      non_service_resources(release_doc).each(&:delete)
    end

    # used for blue_green deployment
    def non_service_resources(release_doc)
      release_doc.resources - service_resources(release_doc)
    end

    # used for blue_green deployment
    def service_resources(release_doc)
      release_doc.resources.select { |r| r.is_a?(Kubernetes::Resource::Service) }
    end
  end
end
