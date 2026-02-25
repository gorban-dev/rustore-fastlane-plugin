require "spec_helper"
require "tempfile"

RSpec.describe Fastlane::RuStore::RustoreClient do
  let(:logger) { raising_logger_double }
  let(:auth)   { instance_double(Fastlane::RuStore::RustoreAuth, token: TEST_JWE_TOKEN) }
  let(:client) { described_class.new(auth: auth, logger: logger) }

  # Base URL for all API stubs — must match BASE_URL + relative paths in client
  def api_url(path)
    "#{RUSTORE_API_BASE}/#{path}"
  end

  # ── Draft management ──────────────────────────────────────────────────────

  describe "#create_draft" do
    before do
      stub_request(:post, api_url("application/#{TEST_PACKAGE}/version"))
        .to_return(
          status:  200,
          body:    JSON.generate({ code: "OK", body: { publishId: TEST_VERSION_ID } }),
          headers: { "Content-Type" => "application/json" }
        )
    end

    it "returns the versionId as integer" do
      expect(client.create_draft(package_name: TEST_PACKAGE)).to eq(TEST_VERSION_ID)
    end

    it "sends the Public-Token header" do
      client.create_draft(package_name: TEST_PACKAGE)
      expect(WebMock).to have_requested(:post, api_url("application/#{TEST_PACKAGE}/version"))
        .with(headers: { "Public-Token" => TEST_JWE_TOKEN })
    end
  end

  describe "#find_existing_draft" do
    context "when a DRAFT version exists" do
      let(:draft) { { "publishId" => 99, "versionStatus" => "DRAFT" } }

      before do
        stub_request(:get, api_url("application/#{TEST_PACKAGE}/version"))
          .to_return(
            status:  200,
            body:    JSON.generate({ code: "OK", body: { content: [draft] } }),
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns the draft hash" do
        result = client.find_existing_draft(package_name: TEST_PACKAGE)
        expect(result["publishId"]).to eq(99)
      end
    end

    context "when no DRAFT exists" do
      before do
        stub_request(:get, api_url("application/#{TEST_PACKAGE}/version"))
          .to_return(
            status:  200,
            body:    JSON.generate({ code: "OK", body: { content: [] } }),
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns nil" do
        expect(client.find_existing_draft(package_name: TEST_PACKAGE)).to be_nil
      end
    end
  end

  # ── File uploads ──────────────────────────────────────────────────────────

  describe "#upload_aab" do
    let(:aab_file) { Tempfile.new(["test", ".aab"]).tap { |f| f.write("aab"); f.rewind } }
    after { aab_file.close; aab_file.unlink }

    before do
      stub_request(:post, api_url("application/#{TEST_PACKAGE}/version/#{TEST_VERSION_ID}/aab"))
        .to_return(
          status:  200,
          body:    JSON.generate({ code: "OK", body: {} }),
          headers: { "Content-Type" => "application/json" }
        )
    end

    it "posts to the aab endpoint" do
      client.upload_aab(package_name: TEST_PACKAGE, version_id: TEST_VERSION_ID, file_path: aab_file.path)
      expect(WebMock).to have_requested(:post, api_url("application/#{TEST_PACKAGE}/version/#{TEST_VERSION_ID}/aab"))
    end
  end

  describe "#upload_apk with HMS params" do
    let(:apk_file) { Tempfile.new(["test", ".apk"]).tap { |f| f.write("apk"); f.rewind } }
    after { apk_file.close; apk_file.unlink }

    before do
      stub_request(:post, /application\/#{TEST_PACKAGE}\/version\/#{TEST_VERSION_ID}\/apk/)
        .to_return(
          status:  200,
          body:    JSON.generate({ code: "OK", body: {} }),
          headers: { "Content-Type" => "application/json" }
        )
    end

    it "sends servicesType=HMS and isMainApk=false as query params" do
      client.upload_apk(
        package_name:  TEST_PACKAGE,
        version_id:    TEST_VERSION_ID,
        file_path:     apk_file.path,
        services_type: "HMS",
        is_main_apk:   false
      )
      expect(WebMock).to have_requested(:post, /servicesType=HMS/).at_least_once
      expect(WebMock).to have_requested(:post, /isMainApk=false/).at_least_once
    end
  end

  # ── Submission ────────────────────────────────────────────────────────────

  describe "#submit_for_review" do
    before do
      stub_request(:post, api_url("application/#{TEST_PACKAGE}/version/#{TEST_VERSION_ID}/commit"))
        .to_return(
          status:  200,
          body:    JSON.generate({ code: "OK", body: {} }),
          headers: { "Content-Type" => "application/json" }
        )
    end

    it "posts to the commit endpoint" do
      client.submit_for_review(package_name: TEST_PACKAGE, version_id: TEST_VERSION_ID)
      expect(WebMock).to have_requested(
        :post, api_url("application/#{TEST_PACKAGE}/version/#{TEST_VERSION_ID}/commit")
      )
    end
  end

  # ── Moderation polling ────────────────────────────────────────────────────

  describe "#wait_for_moderation" do
    def stub_version_status(status, times: 1)
      stub_request(:get, api_url("application/#{TEST_PACKAGE}/version/#{TEST_VERSION_ID}"))
        .to_return(
          status:  200,
          body:    JSON.generate({ code: "OK", body: { versionStatus: status } }),
          headers: { "Content-Type" => "application/json" }
        ).times(times)
    end

    it "returns immediately when already APPROVED" do
      stub_version_status("APPROVED")
      allow(client).to receive(:sleep)
      result = client.wait_for_moderation(
        package_name: TEST_PACKAGE, version_id: TEST_VERSION_ID,
        timeout: 60, poll_interval: 1
      )
      expect(result).to eq("APPROVED")
    end

    it "polls until APPROVED" do
      stub_version_status("IN_REVIEW", times: 2)
      stub_version_status("APPROVED",  times: 1)
      allow(client).to receive(:sleep)
      result = client.wait_for_moderation(
        package_name: TEST_PACKAGE, version_id: TEST_VERSION_ID,
        timeout: 120, poll_interval: 1
      )
      expect(result).to eq("APPROVED")
    end

    it "raises on DECLINED status" do
      stub_version_status("DECLINED")
      allow(client).to receive(:sleep)
      expect do
        client.wait_for_moderation(
          package_name: TEST_PACKAGE, version_id: TEST_VERSION_ID,
          timeout: 60, poll_interval: 1
        )
      end.to raise_error(FastlaneCore::Interface::FastlaneError, /Moderation declined/)
    end
  end

  # ── Error handling ────────────────────────────────────────────────────────

  describe "HTTP error handling" do
    it "raises with a meaningful message on 404" do
      stub_request(:get, api_url("application/#{TEST_PACKAGE}/version"))
        .to_return(
          status:  404,
          body:    JSON.generate({ message: "Not found" }),
          headers: { "Content-Type" => "application/json" }
        )

      expect do
        client.find_existing_draft(package_name: TEST_PACKAGE)
      end.to raise_error(FastlaneCore::Interface::FastlaneError, /API request failed \[404\]/)
    end

    it "raises when API returns non-OK code in a 200 response" do
      stub_request(:post, api_url("application/#{TEST_PACKAGE}/version"))
        .to_return(
          status:  200,
          body:    JSON.generate({ code: "ERROR", message: "Version already exists" }),
          headers: { "Content-Type" => "application/json" }
        )

      expect do
        client.create_draft(package_name: TEST_PACKAGE)
      end.to raise_error(FastlaneCore::Interface::FastlaneError, /API returned error code 'ERROR'/)
    end
  end
end
