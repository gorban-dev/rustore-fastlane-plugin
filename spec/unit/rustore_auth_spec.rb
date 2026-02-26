require "spec_helper"

RSpec.describe Fastlane::RuStore::RustoreAuth do
  # Use a raising_logger_double so that logger.error propagates as expected
  let(:logger) { raising_logger_double }
  let(:auth)   { described_class.new(key_id: "test-key-id", private_key: test_private_key_pem, logger: logger) }

  describe "#token" do
    context "when auth endpoint returns a valid JWE token" do
      before { stub_auth_success }

      it "returns the JWE token" do
        expect(auth.token).to eq(TEST_JWE_TOKEN)
      end

      it "makes exactly one HTTP request for multiple #token calls within TTL" do
        3.times { auth.token }
        expect(WebMock).to have_requested(:post, RUSTORE_AUTH_URL).once
      end
    end

    context "when auth endpoint returns 401" do
      before { stub_auth_failure(status: 401, message: "Unauthorized") }

      it "raises FastlaneError via logger" do
        expect { auth.token }.to raise_error(FastlaneCore::Interface::FastlaneError, /Authentication failed/)
      end
    end

    context "when response is missing jwe field" do
      before do
        stub_request(:post, RUSTORE_AUTH_URL)
          .to_return(
            status:  200,
            body:    JSON.generate({ code: "OK", body: {} }),
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "raises FastlaneError about missing token" do
        expect { auth.token }.to raise_error(FastlaneCore::Interface::FastlaneError, /JWE token/)
      end
    end
  end

  describe "#refresh!" do
    it "fetches a new token on every call" do
      stub_auth_success
      auth.refresh!
      auth.refresh!
      expect(WebMock).to have_requested(:post, RUSTORE_AUTH_URL).twice
    end
  end

  describe "RSA key loading" do
    context "with a valid PEM string" do
      before { stub_auth_success }

      it "loads and returns a token successfully" do
        expect { auth.token }.not_to raise_error
      end
    end

    context "with an invalid key string" do
      it "raises FastlaneError about key loading during initialization" do
        expect do
          described_class.new(key_id: "k", private_key: "not-a-key", logger: logger)
        end.to raise_error(FastlaneCore::Interface::FastlaneError, /RSA private key/)
      end
    end

    context "with raw base64 (no PEM headers)" do
      before { stub_auth_success }

      it "auto-wraps bare base64 and loads the key successfully" do
        # Strip PEM headers generically — simulates a CI secret stored as raw base64
        # (works for both PKCS#8 "BEGIN PRIVATE KEY" and PKCS#1 "BEGIN RSA PRIVATE KEY")
        bare_b64 = test_private_key_pem
                     .gsub(/-----BEGIN [A-Z ]+-----/, "")
                     .gsub(/-----END [A-Z ]+-----/, "")
                     .gsub(/\s+/, "")

        expect do
          auth_bare = described_class.new(key_id: "test-key-id", private_key: bare_b64, logger: logger)
          auth_bare.token
        end.not_to raise_error
      end
    end
  end
end
