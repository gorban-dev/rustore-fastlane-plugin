require "spec_helper"
require "tempfile"

RSpec.describe Fastlane::Actions::RustoreCheckAction do
  let(:rsa_pem)      { test_private_key_pem }
  let(:versions_url) { "#{RUSTORE_API_BASE}/application/#{TEST_PACKAGE}/version?page=0&size=20" }

  def run_check(private_key: rsa_pem, extra: "")
    Fastlane::FastFile.new.parse(<<~LANE).runner.execute(:test)
      lane :test do
        rustore_check(
          package_name: '#{TEST_PACKAGE}',
          key_id:       'test-key',
          private_key:  #{private_key.inspect}#{extra}
        )
      end
    LANE
  end

  def stub_versions(status: 200, body:)
    stub_request(:get, versions_url)
      .to_return(status: status, body: JSON.generate(body), headers: { "Content-Type" => "application/json" })
  end

  # Mutating requests must never be sent by the check.
  after do
    expect(WebMock).not_to have_requested(:post, /#{Regexp.escape(RUSTORE_API_BASE)}/)
    expect(WebMock).not_to have_requested(:delete, /rustore\.ru/)
    expect(WebMock).not_to have_requested(:any, /public-api\.rustore\.ru/)
  end

  context "when the app has versions" do
    let(:versions) do
      (1..7).map do |i|
        { "versionId" => i, "versionName" => "1.#{i}", "versionCode" => 100 + i, "versionStatus" => "PREVIOUS_ACTIVE" }
      end
    end

    before do
      stub_auth_success
      stub_versions(body: { code: "OK", body: { content: versions } })
    end

    it "returns the versions and logs the 5 latest" do
      result = run_check

      expect(result).to eq(versions)
      expect(FastlaneCore::UI).to have_received(:message).with(/versionId=7 versionName=1\.7 versionCode=107 versionStatus=PREVIOUS_ACTIVE/)
      expect(FastlaneCore::UI).to have_received(:message).with(/versionId=3 /)
      expect(FastlaneCore::UI).not_to have_received(:message).with(/versionId=2 /)
      expect(FastlaneCore::UI).to have_received(:success).with(/RuStore OK — ключ рабочий, версий: 7/)
    end

    it "does not touch drafts" do
      run_check
      expect(WebMock).not_to have_requested(:get, /versionStatuses=DRAFT/)
    end
  end

  context "when the app has no versions" do
    before do
      stub_auth_success
      stub_versions(body: { code: "OK", body: { content: [] } })
    end

    it "succeeds and returns []" do
      expect(run_check).to eq([])
      expect(FastlaneCore::UI).to have_received(:success).with(/версий у #{TEST_PACKAGE} нет/)
    end
  end

  context "when RuStore answers 404 on the version list" do
    before do
      stub_auth_success
      stub_versions(status: 404, body: { code: "ERROR", message: "any text" })
    end

    it "counts it as success" do
      expect(run_check).to eq([])
      expect(FastlaneCore::UI).to have_received(:success).with(/ключ покрывает #{TEST_PACKAGE}; активных версий нет/)
    end
  end

  context "when RuStore answers 403 on the version list" do
    before do
      stub_auth_success
      stub_versions(status: 403, body: { code: "ERROR", message: "Forbidden" })
    end

    it "fails with the hint" do
      expect { run_check }.to raise_error(FastlaneCore::Interface::FastlaneError)
      expect(FastlaneCore::UI).to have_received(:error).with(/Key does not have permission/)
    end
  end

  context "when authentication fails" do
    before { stub_auth_failure }

    it "fails and does not request versions" do
      expect { run_check }.to raise_error(FastlaneCore::Interface::FastlaneError)
      expect(FastlaneCore::UI).to have_received(:error).with(/key_id and private_key/)
      expect(WebMock).not_to have_requested(:get, versions_url)
    end
  end

  context "when the key is empty" do
    it "fails before any request" do
      expect { run_check(private_key: "") }
        .to raise_error(FastlaneCore::Interface::FastlaneError, /private_key или private_key_path не задан/)
      expect(WebMock).not_to have_requested(:any, /rustore\.ru/)
    end

    it "fails when the key is only whitespace" do
      expect { run_check(private_key: "  \n") }
        .to raise_error(FastlaneCore::Interface::FastlaneError, /private_key или private_key_path не задан/)
    end
  end

  context "when the key comes from private_key_path" do
    let(:key_file) { Tempfile.new(["rustore", ".pem"]).tap { |f| f.write(rsa_pem); f.flush } }

    after { key_file.close; key_file.unlink }

    before do
      stub_auth_success
      stub_versions(body: { code: "OK", body: { content: [] } })
    end

    it "reads the key from the file" do
      Fastlane::FastFile.new.parse(<<~LANE).runner.execute(:test)
        lane :test do
          rustore_check(package_name: '#{TEST_PACKAGE}', key_id: 'test-key', private_key_path: '#{key_file.path}')
        end
      LANE
      expect(WebMock).to have_requested(:post, RUSTORE_AUTH_URL)
    end
  end
end
