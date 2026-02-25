require "spec_helper"

RSpec.describe Fastlane::RuStore::RustoreLogger do
  let(:logger) { described_class.new(total_steps: 7) }

  describe "#step" do
    it "outputs a header with step info" do
      expect(FastlaneCore::UI).to receive(:header).with("[RuStore] Step 1/7: Authentication")
      logger.step(1, "Authentication")
    end
  end

  describe "#success" do
    it "prefixes with checkmark" do
      expect(FastlaneCore::UI).to receive(:success).with("[RuStore] ✓ Done")
      logger.success("Done")
    end
  end

  describe "#warning" do
    it "uses UI.important" do
      expect(FastlaneCore::UI).to receive(:important).with("[RuStore] ⚠ Watch out")
      logger.warning("Watch out")
    end
  end

  describe "#info" do
    it "uses UI.message" do
      expect(FastlaneCore::UI).to receive(:message).with("[RuStore] hello")
      logger.info("hello")
    end
  end

  describe "#error (raise_error: false)" do
    it "calls UI.error without raising" do
      expect(FastlaneCore::UI).to receive(:error).with("[RuStore] ✗ Something")
      expect { logger.error("Something", raise_error: false) }.not_to raise_error
    end

    it "also prints the hint" do
      expect(FastlaneCore::UI).to receive(:error).with("[RuStore] ✗ Oops")
      expect(FastlaneCore::UI).to receive(:error).with("[RuStore]   → Fix it")
      logger.error("Oops", hint: "Fix it", raise_error: false)
    end
  end

  describe "#table" do
    it "outputs each row as a message" do
      expect(FastlaneCore::UI).to receive(:message).twice
      logger.table([["key", "value"], ["another", "row"]])
    end
  end

  describe "GitLab CI mode" do
    around do |example|
      ENV["GITLAB_CI"] = "true"
      example.run
      ENV.delete("GITLAB_CI")
    end

    let(:gitlab_logger) { described_class.new(total_steps: 3) }

    it "writes GitLab section_start to stdout on step" do
      expect($stdout).to receive(:print).with(a_string_including("section_start"))
      expect($stdout).to receive(:flush)
      gitlab_logger.step(1, "Test step")
    end

    it "closes previous section before opening a new one" do
      expect($stdout).to receive(:print).ordered.with(a_string_including("section_start"))
      expect($stdout).to receive(:flush).ordered
      expect($stdout).to receive(:print).ordered.with(a_string_including("section_end"))
      expect($stdout).to receive(:flush).ordered
      expect($stdout).to receive(:print).ordered.with(a_string_including("section_start"))
      expect($stdout).to receive(:flush).ordered
      gitlab_logger.step(1, "First")
      gitlab_logger.step(2, "Second")
    end
  end
end
