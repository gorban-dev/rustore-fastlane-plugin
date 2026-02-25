require "spec_helper"
require "tempfile"

RSpec.describe Fastlane::Actions::RustoreUploadAction do
  let(:rsa_pem)  { test_private_key_pem }
  let(:aab_file) { Tempfile.new(["release", ".aab"]).tap { |f| f.write("aab"); f.rewind } }
  let(:apk_file) { Tempfile.new(["hms",     ".apk"]).tap { |f| f.write("apk"); f.rewind } }

  after { [aab_file, apk_file].each { |f| f.close; f.unlink } }

  def api(path)
    "#{RUSTORE_API_BASE}/#{path}"
  end

  def stub_full_workflow
    stub_auth_success

    stub_request(:get, api("application/#{TEST_PACKAGE}/version"))
      .to_return(status: 200,
                 body: JSON.generate({ code: "OK", body: { content: [] } }),
                 headers: { "Content-Type" => "application/json" })

    stub_request(:post, api("application/#{TEST_PACKAGE}/version"))
      .to_return(status: 200,
                 body: JSON.generate({ code: "OK", body: { publishId: TEST_VERSION_ID } }),
                 headers: { "Content-Type" => "application/json" })

    stub_request(:post, api("application/#{TEST_PACKAGE}/version/#{TEST_VERSION_ID}/aab"))
      .to_return(status: 200, body: JSON.generate({ code: "OK", body: {} }),
                 headers: { "Content-Type" => "application/json" })

    stub_request(:post, /application\/#{TEST_PACKAGE}\/version\/#{TEST_VERSION_ID}\/apk/)
      .to_return(status: 200, body: JSON.generate({ code: "OK", body: {} }),
                 headers: { "Content-Type" => "application/json" })

    stub_request(:post, api("application/#{TEST_PACKAGE}/version/#{TEST_VERSION_ID}/commit"))
      .to_return(status: 200, body: JSON.generate({ code: "OK", body: {} }),
                 headers: { "Content-Type" => "application/json" })

    stub_request(:put, api("application/#{TEST_PACKAGE}/version/#{TEST_VERSION_ID}/publish-settings"))
      .to_return(status: 200, body: JSON.generate({ code: "OK", body: {} }),
                 headers: { "Content-Type" => "application/json" })
  end

  def run_lane(extra_params = "")
    Fastlane::FastFile.new.parse(<<~LANE).runner.execute(:test)
      lane :test do
        rustore_upload(
          package_name: '#{TEST_PACKAGE}',
          key_id:       'test-key',
          private_key:  #{rsa_pem.inspect},
          aab_path:     '#{aab_file.path}',
          hms_apk_path: '#{apk_file.path}',
          publish_type: 'INSTANTLY'
          #{extra_params}
        )
      end
    LANE
  end

  describe "full workflow — AAB (GMS) + HMS APK" do
    before { stub_full_workflow }

    it "completes without error" do
      expect { run_lane }.not_to raise_error
    end

    it "authenticates first" do
      run_lane
      expect(WebMock).to have_requested(:post, RUSTORE_AUTH_URL)
    end

    it "creates a new version draft" do
      run_lane
      expect(WebMock).to have_requested(:post, api("application/#{TEST_PACKAGE}/version"))
    end

    it "uploads AAB to the /aab endpoint" do
      run_lane
      expect(WebMock).to have_requested(
        :post, api("application/#{TEST_PACKAGE}/version/#{TEST_VERSION_ID}/aab")
      )
    end

    it "uploads HMS APK with servicesType=HMS and isMainApk=false" do
      run_lane
      expect(WebMock).to have_requested(:post, /servicesType=HMS/).at_least_once
      expect(WebMock).to have_requested(:post, /isMainApk=false/).at_least_once
    end

    it "submits for moderation" do
      run_lane
      expect(WebMock).to have_requested(
        :post, api("application/#{TEST_PACKAGE}/version/#{TEST_VERSION_ID}/commit")
      )
    end

    it "configures publication settings" do
      run_lane
      expect(WebMock).to have_requested(
        :put, api("application/#{TEST_PACKAGE}/version/#{TEST_VERSION_ID}/publish-settings")
      )
    end

    it "does NOT call the /publish endpoint" do
      run_lane
      expect(WebMock).not_to have_requested(
        :post, api("application/#{TEST_PACKAGE}/version/#{TEST_VERSION_ID}/publish")
      )
    end

    it "does NOT call the moderation status endpoint" do
      run_lane
      expect(WebMock).not_to have_requested(
        :get, api("application/#{TEST_PACKAGE}/version/#{TEST_VERSION_ID}")
      )
    end
  end

  describe "publish_type: MANUAL" do
    before { stub_full_workflow }

    it "configures MANUAL and does NOT call /publish endpoint" do
      Fastlane::FastFile.new.parse(<<~LANE).runner.execute(:test)
        lane :test do
          rustore_upload(
            package_name: '#{TEST_PACKAGE}',
            key_id:       'test-key',
            private_key:  #{rsa_pem.inspect},
            aab_path:     '#{aab_file.path}',
            publish_type: 'MANUAL'
          )
        end
      LANE

      expect(WebMock).to have_requested(:put, /publish-settings/)
        .with(body: /MANUAL/)
      expect(WebMock).not_to have_requested(
        :post, api("application/#{TEST_PACKAGE}/version/#{TEST_VERSION_ID}/publish")
      )
    end
  end

  describe "publish_type: DELAYED" do
    before { stub_full_workflow }

    it "passes release_date in publish-settings" do
      Fastlane::FastFile.new.parse(<<~LANE).runner.execute(:test)
        lane :test do
          rustore_upload(
            package_name: '#{TEST_PACKAGE}',
            key_id:       'test-key',
            private_key:  #{rsa_pem.inspect},
            aab_path:     '#{aab_file.path}',
            publish_type: 'DELAYED',
            release_date: '2025-06-01T10:00:00+03:00'
          )
        end
      LANE

      expect(WebMock).to have_requested(:put, /publish-settings/)
        .with(body: /DELAYED/)
    end
  end

  describe "existing draft cleanup" do
    before do
      stub_auth_success

      stub_request(:get, api("application/#{TEST_PACKAGE}/version"))
        .to_return(
          status: 200,
          body: JSON.generate({ code: "OK",
                                body: { content: [{ "publishId" => 99, "versionStatus" => "DRAFT" }] } }),
          headers: { "Content-Type" => "application/json" }
        )

      stub_request(:delete, api("application/#{TEST_PACKAGE}/version/99"))
        .to_return(status: 200, body: JSON.generate({ code: "OK" }),
                   headers: { "Content-Type" => "application/json" })

      stub_request(:post, api("application/#{TEST_PACKAGE}/version"))
        .to_return(status: 200,
                   body: JSON.generate({ code: "OK", body: { publishId: TEST_VERSION_ID } }),
                   headers: { "Content-Type" => "application/json" })

      stub_request(:post, api("application/#{TEST_PACKAGE}/version/#{TEST_VERSION_ID}/aab"))
        .to_return(status: 200, body: JSON.generate({ code: "OK", body: {} }),
                   headers: { "Content-Type" => "application/json" })

      stub_request(:post, api("application/#{TEST_PACKAGE}/version/#{TEST_VERSION_ID}/commit"))
        .to_return(status: 200, body: JSON.generate({ code: "OK", body: {} }),
                   headers: { "Content-Type" => "application/json" })

      stub_request(:put, api("application/#{TEST_PACKAGE}/version/#{TEST_VERSION_ID}/publish-settings"))
        .to_return(status: 200, body: JSON.generate({ code: "OK", body: {} }),
                   headers: { "Content-Type" => "application/json" })
    end

    it "deletes the existing draft before creating a new one" do
      Fastlane::FastFile.new.parse(<<~LANE).runner.execute(:test)
        lane :test do
          rustore_upload(
            package_name: '#{TEST_PACKAGE}',
            key_id:       'test-key',
            private_key:  #{rsa_pem.inspect},
            aab_path:     '#{aab_file.path}'
          )
        end
      LANE
      expect(WebMock).to have_requested(:delete, api("application/#{TEST_PACKAGE}/version/99"))
    end
  end

  describe "parameter validation" do
    it "raises when neither aab_path nor apk_path is provided" do
      stub_auth_success

      stub_request(:get, api("application/#{TEST_PACKAGE}/version"))
        .to_return(status: 200,
                   body: JSON.generate({ code: "OK", body: { content: [] } }),
                   headers: { "Content-Type" => "application/json" })

      stub_request(:post, api("application/#{TEST_PACKAGE}/version"))
        .to_return(status: 200,
                   body: JSON.generate({ code: "OK", body: { publishId: TEST_VERSION_ID } }),
                   headers: { "Content-Type" => "application/json" })

      expect do
        Fastlane::FastFile.new.parse(<<~LANE).runner.execute(:test)
          lane :test do
            rustore_upload(
              package_name: '#{TEST_PACKAGE}',
              key_id:       'test-key',
              private_key:  #{rsa_pem.inspect}
            )
          end
        LANE
      end.to raise_error(FastlaneCore::Interface::FastlaneError, /No build file provided/)
    end
  end
end
