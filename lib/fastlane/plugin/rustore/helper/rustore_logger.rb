require "fastlane_core/ui/ui"

module Fastlane
  module RuStore
    # Structured logger for RuStore plugin.
    #
    # In standard mode outputs via FastlaneCore::UI.* helpers.
    # When GITLAB_CI env var is set, wraps each step in GitLab CI
    # collapsible section markers so they appear as foldable blocks
    # in the Pipeline web UI.
    #
    # Usage:
    #   logger = RustoreLogger.new(total_steps: 7)
    #   logger.step(1, "Authentication")
    #   logger.success("Token obtained")
    #   logger.info("Expires in 900s")
    #   logger.error("Something failed", hint: "Check your key_id")
    class RustoreLogger
      PREFIX = "[RuStore]"

      # ANSI / GitLab CI section escape sequences
      SECTION_START = "\e[0Ksection_start:%<ts>d:%<name>s[collapsed=true]\r\e[0K"
      SECTION_END   = "\e[0Ksection_end:%<ts>d:%<name>s\r\e[0K"

      UI = FastlaneCore::UI

      def initialize(total_steps: 0)
        @total_steps  = total_steps
        @gitlab_ci    = ENV["GITLAB_CI"] == "true" || ENV["GITLAB_CI"] == "1"
        @open_section = nil
      end

      # ── Step header ──────────────────────────────────────────────────────────

      def step(number, title)
        close_section if @open_section

        label        = @total_steps > 0 ? "Step #{number}/#{@total_steps}: #{title}" : title
        section_name = "rustore_step_#{number}"

        if @gitlab_ci
          ts = Time.now.to_i
          $stdout.print(format(SECTION_START, ts: ts, name: section_name) + "#{PREFIX} #{label}\n")
          $stdout.flush
          @open_section = { name: section_name }
        else
          UI.header("#{PREFIX} #{label}")
        end
      end

      # ── Message levels ───────────────────────────────────────────────────────

      def info(message)
        UI.message("#{PREFIX} #{message}")
      end

      def success(message)
        UI.success("#{PREFIX} ✓ #{message}")
      end

      def warning(message)
        UI.important("#{PREFIX} ⚠ #{message}")
      end

      def verbose(message)
        UI.verbose("#{PREFIX} #{message}")
      end

      # Logs a structured error with an optional actionable hint, then raises
      # so the pipeline fails cleanly.
      #
      # @param message     [String]  what went wrong
      # @param hint        [String]  how to fix it (optional)
      # @param raise_error [Boolean] whether to raise after logging (default true)
      def error(message, hint: nil, raise_error: true)
        close_section if @open_section
        UI.error("#{PREFIX} ✗ #{message}")
        UI.error("#{PREFIX}   → #{hint}") if hint
        UI.user_error!(message) if raise_error
      end

      # Logs a key/value table for step context (e.g. upload params)
      def table(rows)
        max_key = rows.map { |k, _| k.to_s.length }.max || 0
        rows.each do |key, value|
          UI.message("#{PREFIX}   %-#{max_key}s : %s" % [key, value])
        end
      end

      # Close the currently open GitLab CI section (called automatically
      # before each new step and at the end of the workflow).
      def finalize
        close_section
      end

      private

      def close_section
        return unless @gitlab_ci && @open_section

        ts = Time.now.to_i
        $stdout.print(format(SECTION_END, ts: ts, name: @open_section[:name]) + "\n")
        $stdout.flush
        @open_section = nil
      end
    end
  end
end
