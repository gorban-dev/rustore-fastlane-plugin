require "openssl"

module Fastlane
  module RustorePublish
    # RuStore Public API host and TLS trust settings.
    #
    # RuStore moved the Public API to the "-m" domain, which is served with a
    # certificate issued by the Russian Trusted Root CA (Ministry of Digital
    # Development). That root is not in the default OS/Ruby trust stores, so the
    # plugin ships it and adds it on top of the system roots.
    #
    # Reference: https://www.rustore.ru/developer/blog/rustore-obnovlyaet-sertifikaty-i-domeny-chto-nuzhno-sdelat-razrabotchikam
    module RustoreEndpoint
      HOST     = "public-api-m.rustore.ru"
      BASE_URL = "https://#{HOST}/public/v1"
      AUTH_URL = "https://#{HOST}/public/auth"
      CA_FILE  = File.expand_path("../certs/russian_trusted_root_ca.crt", __dir__)

      # System roots + Russian Trusted Root CA.
      def self.cert_store
        store = OpenSSL::X509::Store.new
        store.set_default_paths
        root = OpenSSL::X509::Certificate.new(File.read(CA_FILE))
        begin
          store.add_cert(root)
        rescue OpenSSL::X509::StoreError
          # Root is already present in the system store
        end
        store
      end
    end
  end
end
