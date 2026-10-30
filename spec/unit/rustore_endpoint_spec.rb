require "spec_helper"

RSpec.describe Fastlane::RustorePublish::RustoreEndpoint do
  it "points to the -m domain" do
    expect(described_class::BASE_URL).to eq("https://public-api-m.rustore.ru/public/v1")
    expect(described_class::AUTH_URL).to eq("https://public-api-m.rustore.ru/public/auth")
  end

  describe ".cert_store" do
    it "trusts the bundled Russian Trusted Root CA" do
      root = OpenSSL::X509::Certificate.new(File.read(described_class::CA_FILE))
      expect(root.subject.to_s).to include("Russian Trusted Root CA")
      expect(described_class.cert_store.verify(root)).to be(true)
    end

    it "raises when the bundled certificate is missing" do
      stub_const("#{described_class}::CA_FILE", "/nonexistent/root.crt")
      expect { described_class.cert_store }.to raise_error(Errno::ENOENT)
    end
  end
end
