require "spec_helper"
require "tempfile"

RSpec.describe Fastlane::RustorePublish::RustoreClient do
  let(:logger) { raising_logger_double }
  let(:auth)   { instance_double(Fastlane::RustorePublish::RustoreAuth, token: TEST_JWE_TOKEN) }
  let(:client) { described_class.new(auth: auth, logger: logger) }

  # Base URL for all API stubs — must match BASE_URL + relative paths in client
  def api_url(path)
    "#{RUSTORE_API_BASE}/#{path}"
  end

  # ── Draft management ──────────────────────────────────────────────────────

  describe "#create_draft" do
    context "when body is a hash with publishId" do
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

    context "when body is the version ID directly (integer)" do
      before do
        stub_request(:post, api_url("application/#{TEST_PACKAGE}/version"))
          .to_return(
            status:  200,
            body:    JSON.generate({ code: "OK", body: TEST_VERSION_ID }),
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns the versionId as integer" do
        expect(client.create_draft(package_name: TEST_PACKAGE)).to eq(TEST_VERSION_ID)
      end
    end
  end

  describe "#find_existing_draft" do
    context "when a DRAFT version exists" do
      let(:draft) { { "publishId" => 99, "versionStatus" => "DRAFT" } }

      before do
        stub_request(:get, api_url("application/#{TEST_PACKAGE}/version?versionStatuses=DRAFT"))
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
        stub_request(:get, api_url("application/#{TEST_PACKAGE}/version?versionStatuses=DRAFT"))
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
      stub_request(:post, %r{application/#{TEST_PACKAGE}/version/#{TEST_VERSION_ID}/commit})
        .to_return(
          status:  200,
          body:    JSON.generate({ code: "OK", body: {} }),
          headers: { "Content-Type" => "application/json" }
        )
    end

    it "posts to the commit endpoint with priorityUpdate=0 by default" do
      client.submit_for_review(package_name: TEST_PACKAGE, version_id: TEST_VERSION_ID)
      expect(WebMock).to have_requested(
        :post, api_url("application/#{TEST_PACKAGE}/version/#{TEST_VERSION_ID}/commit?priorityUpdate=0")
      )
    end

    it "passes update_priority as the priorityUpdate query param" do
      client.submit_for_review(package_name: TEST_PACKAGE, version_id: TEST_VERSION_ID, update_priority: 3)
      expect(WebMock).to have_requested(
        :post, api_url("application/#{TEST_PACKAGE}/version/#{TEST_VERSION_ID}/commit?priorityUpdate=3")
      )
    end
  end

  # ── Upload diagnostics ────────────────────────────────────────────────────

  describe "upload logging and failures" do
    let(:aab_file) { Tempfile.new(["app", ".aab"]).tap { |f| f.write("aab"); f.rewind } }
    let(:aab_url)  { api_url("application/#{TEST_PACKAGE}/version/#{TEST_VERSION_ID}/aab") }
    after { aab_file.close; aab_file.unlink }

    def upload(c = client)
      c.upload_aab(package_name: TEST_PACKAGE, version_id: TEST_VERSION_ID, file_path: aab_file.path)
    end

    it "logs permissions and SDKs detected by RuStore" do
      stub_request(:post, aab_url).to_return(
        status: 200,
        body:   JSON.generate({
          code: "OK",
          body: {
            permissions:      { location: [{ permission: "android.permission.ACCESS_FINE_LOCATION" }] },
            autoDetectedSdks: { ads: ["com.google.android.gms.ads"], payment: [] }
          }
        })
      )
      upload
      expect(logger).to have_received(:info).with(/android\.permission\.ACCESS_FINE_LOCATION/)
      expect(logger).to have_received(:info).with(/ads: com\.google\.android\.gms\.ads/)
    end

    it "logs how long RuStore took to respond" do
      stub_request(:post, aab_url).to_return(status: 200, body: JSON.generate({ code: "OK", body: {} }))
      upload
      expect(logger).to have_received(:info).with(/RuStore responded in \d+s/)
    end

    it "logs a heartbeat while waiting for the response" do
      stub_request(:post, aab_url).to_return do
        sleep 0.3
        { status: 200, body: JSON.generate({ code: "OK", body: {} }) }
      end
      upload(described_class.new(auth: auth, logger: logger, wait_log_interval: 0.05))
      expect(logger).to have_received(:info).with(/Waiting for RuStore response/).at_least(:once)
    end

    it "explains a read timeout and stops the heartbeat thread" do
      stub_request(:post, aab_url).to_raise(Net::ReadTimeout)
      threads_before = Thread.list.size
      expect { upload }.to raise_error(
        FastlaneCore::Interface::FastlaneError,
        /did not respond to the upload of app.*\.aab within 900s \(versionId=#{TEST_VERSION_ID}\).*upload_timeout/m
      )
      expect(Thread.list.size).to eq(threads_before)
    end

    it "uses the configured upload timeout in the message" do
      stub_request(:post, aab_url).to_raise(Net::ReadTimeout)
      expect { upload(described_class.new(auth: auth, logger: logger, upload_timeout: 1200)) }
        .to raise_error(FastlaneCore::Interface::FastlaneError, /within 1200s/)
    end

    it "explains a 504 with an HTML body without dumping the HTML" do
      stub_request(:post, aab_url).to_return(status: 504, body: "<html><body>upstream request timeout</body></html>")
      expect { upload }.to raise_error(FastlaneCore::Interface::FastlaneError) { |e|
        expect(e.message).to include("[504]")
        expect(e.message).to include("RuStore side")
        expect(e.message).not_to include("<html>")
      }
    end

    it "hints at the Console declaration for new sensitive permissions" do
      stub_request(:post, aab_url).to_return(
        status: 400,
        body:   JSON.generate({
          code:    "ERROR",
          message: "APK/AAB contains new sensitive permissions: [android.permission.READ_CONTACTS]. " \
                   "Please, upload APK/AAB via the development console and declare permissions."
        })
      )
      expect { upload }.to raise_error(FastlaneCore::Interface::FastlaneError, /RuStore Console/)
    end
  end

  describe "#list_versions" do
    let(:versions_url) { api_url("application/#{TEST_PACKAGE}/version?page=0&size=20") }

    it "returns the versions from body.content" do
      versions = [{ "versionId" => 2, "versionStatus" => "ACTIVE" }, { "versionId" => 1, "versionStatus" => "PREVIOUS_ACTIVE" }]
      stub_request(:get, versions_url)
        .to_return(status: 200, body: JSON.generate({ code: "OK", body: { content: versions } }),
                   headers: { "Content-Type" => "application/json" })

      expect(client.list_versions(package_name: TEST_PACKAGE)).to eq(versions)
      expect(WebMock).to have_requested(:get, versions_url).with(headers: { "Public-Token" => TEST_JWE_TOKEN })
    end

    it "returns [] when there are no versions" do
      stub_request(:get, versions_url)
        .to_return(status: 200, body: JSON.generate({ code: "OK", body: { content: [] } }),
                   headers: { "Content-Type" => "application/json" })

      expect(client.list_versions(package_name: TEST_PACKAGE)).to eq([])
    end

    it "returns [] when body has no content array" do
      stub_request(:get, versions_url)
        .to_return(status: 200, body: JSON.generate({ code: "OK", body: nil }),
                   headers: { "Content-Type" => "application/json" })

      expect(client.list_versions(package_name: TEST_PACKAGE)).to eq([])
    end

    it "raises NotFoundError on 404 whatever the message text" do
      stub_request(:get, versions_url)
        .to_return(status: 404, body: JSON.generate({ message: "Приложение не найдено" }),
                   headers: { "Content-Type" => "application/json" })

      expect { client.list_versions(package_name: TEST_PACKAGE) }
        .to raise_error(described_class::NotFoundError)
    end

    it "fails through the logger on 401" do
      stub_request(:get, versions_url)
        .to_return(status: 401, body: JSON.generate({ message: "Unauthorized" }),
                   headers: { "Content-Type" => "application/json" })

      expect { client.list_versions(package_name: TEST_PACKAGE) }
        .to raise_error(FastlaneCore::Interface::FastlaneError, /\[401\].*check key_id and private_key/m)
    end

    it "uses page_size" do
      stub_request(:get, api_url("application/#{TEST_PACKAGE}/version?page=0&size=5"))
        .to_return(status: 200, body: JSON.generate({ code: "OK", body: { content: [] } }),
                   headers: { "Content-Type" => "application/json" })

      expect(client.list_versions(package_name: TEST_PACKAGE, page_size: 5)).to eq([])
    end
  end

  describe "network errors" do
    let(:drafts_url) { api_url("application/#{TEST_PACKAGE}/version?versionStatuses=DRAFT") }

    it "explains a TLS failure" do
      stub_request(:get, drafts_url).to_raise(OpenSSL::SSL::SSLError.new("certificate verify failed"))
      expect { client.find_existing_draft(package_name: TEST_PACKAGE) }
        .to raise_error(FastlaneCore::Interface::FastlaneError, /TLS.*public-api-m\.rustore\.ru.*Russian Trusted Root CA/m)
    end

    it "explains a connection failure" do
      stub_request(:get, drafts_url).to_raise(SocketError.new("getaddrinfo: nodename nor servname provided"))
      expect { client.find_existing_draft(package_name: TEST_PACKAGE) }
        .to raise_error(FastlaneCore::Interface::FastlaneError, /Could not connect to public-api-m\.rustore\.ru/)
    end
  end

  # ── Error handling ────────────────────────────────────────────────────────

  describe "HTTP error handling" do
    it "raises with a meaningful message on 404" do
      stub_request(:get, api_url("application/#{TEST_PACKAGE}/version?versionStatuses=DRAFT"))
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
