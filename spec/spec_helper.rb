require "webmock/rspec"
require "fastlane"
require "fastlane_core"

# Load all plugin files
$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "fastlane/plugin/rustore"

WebMock.disable_net_connect!

# FastlaneError uses keyword-only initializer.
# `raise FastlaneError.new(...), "msg"` works (Ruby C-level exception(msg)),
# but `raise FastlaneError, "msg"` calls FastlaneError.new("msg") and fails.
# Use this helper to raise FastlaneError with a message in tests.
def raise_fastlane_error(msg)
  exc = FastlaneCore::Interface::FastlaneError.new
  raise exc, msg
end

RSpec.configure do |config|
  config.example_status_persistence_file_path = ".rspec_status"
  config.disable_monkey_patching!
  config.order = :random

  # Silence Fastlane UI output during tests.
  config.before(:each) do
    allow(FastlaneCore::UI).to receive(:message)
    allow(FastlaneCore::UI).to receive(:success)
    allow(FastlaneCore::UI).to receive(:important)
    allow(FastlaneCore::UI).to receive(:error)
    allow(FastlaneCore::UI).to receive(:verbose)
    allow(FastlaneCore::UI).to receive(:header)
    # user_error! naturally raises FastlaneError — let it flow through in test mode
  end
end

# ── Shared test data ──────────────────────────────────────────────────────────

RUSTORE_AUTH_URL = "https://public-api.rustore.ru/public/auth"
RUSTORE_API_BASE = "https://public-api.rustore.ru/public/v1"
TEST_PACKAGE     = "com.example.testapp"
TEST_VERSION_ID  = 42
TEST_JWE_TOKEN   = "eyJhbGciOiJSU0EtT0FFUC0yNTYiLCJlbmMiOiJBMjU2R0NNIn0.test"

def test_rsa_key
  @test_rsa_key ||= OpenSSL::PKey::RSA.generate(1024)
end

def test_private_key_pem
  test_rsa_key.to_pem
end

def stub_auth_success
  stub_request(:post, RUSTORE_AUTH_URL)
    .to_return(
      status:  200,
      body:    JSON.generate({ code: "OK", body: { jwe: TEST_JWE_TOKEN } }),
      headers: { "Content-Type" => "application/json" }
    )
end

def stub_auth_failure(status: 401, message: "Invalid key")
  stub_request(:post, RUSTORE_AUTH_URL)
    .to_return(
      status:  status,
      body:    JSON.generate({ code: "ERROR", message: message }),
      headers: { "Content-Type" => "application/json" }
    )
end

# A logger double where #error raises FastlaneError (mirrors real behavior).
def raising_logger_double
  logger = instance_double(
    Fastlane::RuStore::RustoreLogger,
    verbose: nil, info: nil, success: nil, warning: nil, table: nil, step: nil
  )
  allow(logger).to receive(:error) do |msg, **|
    raise_fastlane_error(msg)
  end
  logger
end
