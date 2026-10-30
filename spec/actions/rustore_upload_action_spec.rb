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

    stub_request(:get, api("application/#{TEST_PACKAGE}/version?versionStatuses=DRAFT"))
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

    stub_request(:post, api("application/#{TEST_PACKAGE}/version/#{TEST_VERSION_ID}/commit?priorityUpdate=0"))
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
          publish_type: 'INSTANTLY'#{extra_params}
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
        :post, api("application/#{TEST_PACKAGE}/version/#{TEST_VERSION_ID}/commit?priorityUpdate=0")
      )
    end

    it "includes publishType in the draft creation request" do
      run_lane
      expect(WebMock).to have_requested(:post, api("application/#{TEST_PACKAGE}/version"))
        .with(body: /publishType/)
    end

    it "does NOT call the /publish-settings endpoint" do
      run_lane
      expect(WebMock).not_to have_requested(
        :put, /publish-settings/
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

      expect(WebMock).to have_requested(:post, api("application/#{TEST_PACKAGE}/version"))
        .with(body: /MANUAL/)
      expect(WebMock).not_to have_requested(
        :post, api("application/#{TEST_PACKAGE}/version/#{TEST_VERSION_ID}/publish")
      )
    end
  end

  describe "publish_type: DELAYED" do
    before { stub_full_workflow }

    it "passes release_date and DELAYED publishType in draft creation" do
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

      expect(WebMock).to have_requested(:post, api("application/#{TEST_PACKAGE}/version"))
        .with(body: /DELAYED/)
      expect(WebMock).to have_requested(:post, api("application/#{TEST_PACKAGE}/version"))
        .with(body: /publishDateTime/)
    end
  end

  describe "existing draft cleanup" do
    before do
      stub_auth_success

      stub_request(:get, api("application/#{TEST_PACKAGE}/version?versionStatuses=DRAFT"))
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

      stub_request(:post, api("application/#{TEST_PACKAGE}/version/#{TEST_VERSION_ID}/commit?priorityUpdate=0"))
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

      stub_request(:get, api("application/#{TEST_PACKAGE}/version?versionStatuses=DRAFT"))
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

    it "rejects update_priority outside 0..5" do
      expect { run_lane(", update_priority: 6") }
        .to raise_error(FastlaneCore::Interface::FastlaneError, /update_priority/)
    end

    it "rejects a non-positive upload_timeout" do
      expect { run_lane(", upload_timeout: 0") }
        .to raise_error(FastlaneCore::Interface::FastlaneError, /upload_timeout/)
    end
  end

  describe "update_priority" do
    before { stub_full_workflow }

    it "passes update_priority to the commit request" do
      stub_request(:post, api("application/#{TEST_PACKAGE}/version/#{TEST_VERSION_ID}/commit?priorityUpdate=5"))
        .to_return(status: 200, body: JSON.generate({ code: "OK", body: {} }),
                   headers: { "Content-Type" => "application/json" })
      run_lane(", update_priority: 5")
      expect(WebMock).to have_requested(
        :post, api("application/#{TEST_PACKAGE}/version/#{TEST_VERSION_ID}/commit?priorityUpdate=5")
      )
    end
  end

  describe "upload_timeout" do
    before { stub_full_workflow }

    it "passes upload_timeout to the client" do
      expect(Fastlane::RustorePublish::RustoreClient).to receive(:new)
        .with(hash_including(upload_timeout: 1200)).and_call_original
      run_lane(", upload_timeout: 1200")
    end
  end

  describe "draft metadata — regression (no new params)" do
    before { stub_full_workflow }

    it "sends exactly whatsNew, moderInfo, and publishType — no extra keys" do
      Fastlane::FastFile.new.parse(<<~LANE).runner.execute(:test)
        lane :test do
          rustore_upload(
            package_name: '#{TEST_PACKAGE}',
            key_id:       'test-key',
            private_key:  #{rsa_pem.inspect},
            aab_path:     '#{aab_file.path}',
            whats_new:    'Notes',
            moder_info:   'Mod',
            publish_type: 'INSTANTLY'
          )
        end
      LANE

      expect(WebMock).to have_requested(:post, api("application/#{TEST_PACKAGE}/version"))
        .with { |req|
          body = JSON.parse(req.body)
          body.keys.sort == %w[moderInfo publishType whatsNew]
        }
    end
  end

  describe "developer_contacts validation" do
    before do
      stub_auth_success
      stub_request(:get, api("application/#{TEST_PACKAGE}/version?versionStatuses=DRAFT"))
        .to_return(status: 200, body: JSON.generate({ code: "OK", body: { content: [] } }),
                   headers: { "Content-Type" => "application/json" })
    end

    def lane_with(extra_param_literal)
      Fastlane::FastFile.new.parse(<<~LANE).runner.execute(:test)
        lane :test do
          rustore_upload(
            package_name:       '#{TEST_PACKAGE}',
            key_id:             'test-key',
            private_key:        #{rsa_pem.inspect},
            aab_path:           '#{aab_file.path}',
            developer_contacts: #{extra_param_literal}
          )
        end
      LANE
    end

    it "rejects an empty Hash" do
      expect { lane_with("{}") }
        .to raise_error(FastlaneCore::Interface::FastlaneError, /at least one of/)
    end

    it "rejects unknown sub-keys" do
      expect { lane_with("{ facebook: 'https://fb.com/x' }") }
        .to raise_error(FastlaneCore::Interface::FastlaneError, /unknown sub-key.*facebook/)
    end
  end

  describe "developer_contacts integration" do
    before { stub_full_workflow }

    it "transforms vk_community to vkCommunity in the request body" do
      Fastlane::FastFile.new.parse(<<~LANE).runner.execute(:test)
        lane :test do
          rustore_upload(
            package_name:       '#{TEST_PACKAGE}',
            key_id:             'test-key',
            private_key:        #{rsa_pem.inspect},
            aab_path:           '#{aab_file.path}',
            developer_contacts: { vk_community: 'https://vk.com/example' }
          )
        end
      LANE

      expect(WebMock).to have_requested(:post, api("application/#{TEST_PACKAGE}/version"))
        .with { |req|
          body = JSON.parse(req.body)
          body["developerContacts"] == { "vkCommunity" => "https://vk.com/example" }
        }
    end

    it "passes email and website through unchanged" do
      Fastlane::FastFile.new.parse(<<~LANE).runner.execute(:test)
        lane :test do
          rustore_upload(
            package_name:       '#{TEST_PACKAGE}',
            key_id:             'test-key',
            private_key:        #{rsa_pem.inspect},
            aab_path:           '#{aab_file.path}',
            developer_contacts: { email: 'a@b.c', website: 'https://x.io' }
          )
        end
      LANE

      expect(WebMock).to have_requested(:post, api("application/#{TEST_PACKAGE}/version"))
        .with { |req|
          body = JSON.parse(req.body)
          body["developerContacts"] == { "email" => "a@b.c", "website" => "https://x.io" }
        }
    end

    it "accepts string-keyed sub-keys (k.to_sym normalization)" do
      Fastlane::FastFile.new.parse(<<~LANE).runner.execute(:test)
        lane :test do
          rustore_upload(
            package_name:       '#{TEST_PACKAGE}',
            key_id:             'test-key',
            private_key:        #{rsa_pem.inspect},
            aab_path:           '#{aab_file.path}',
            developer_contacts: { 'vk_community' => 'https://vk.com/strings' }
          )
        end
      LANE

      expect(WebMock).to have_requested(:post, api("application/#{TEST_PACKAGE}/version"))
        .with { |req|
          body = JSON.parse(req.body)
          body["developerContacts"] == { "vkCommunity" => "https://vk.com/strings" }
        }
    end
  end

  describe "draft metadata — string fields" do
    before { stub_full_workflow }

    def lane_with(params_extra)
      Fastlane::FastFile.new.parse(<<~LANE).runner.execute(:test)
        lane :test do
          rustore_upload(
            package_name: '#{TEST_PACKAGE}',
            key_id:       'test-key',
            private_key:  #{rsa_pem.inspect},
            aab_path:     '#{aab_file.path}',
            #{params_extra}
          )
        end
      LANE
    end

    it "sends app_name as appName" do
      lane_with("app_name: 'My App'")
      expect(WebMock).to have_requested(:post, api("application/#{TEST_PACKAGE}/version"))
        .with { |req| JSON.parse(req.body)["appName"] == "My App" }
    end

    it "rejects app_name longer than 50 chars" do
      expect { lane_with("app_name: '#{"x" * 51}'") }
        .to raise_error(FastlaneCore::Interface::FastlaneError, /app_name.*50/)
    end

    it "sends app_type as appType (MAIN)" do
      lane_with("app_type: 'MAIN'")
      expect(WebMock).to have_requested(:post, api("application/#{TEST_PACKAGE}/version"))
        .with { |req| JSON.parse(req.body)["appType"] == "MAIN" }
    end

    it "rejects app_type not in {GAMES, MAIN}" do
      expect { lane_with("app_type: 'TOOL'") }
        .to raise_error(FastlaneCore::Interface::FastlaneError, /GAMES.*MAIN/)
    end

    it "sends age_legal as ageLegal" do
      lane_with("age_legal: '12+'")
      expect(WebMock).to have_requested(:post, api("application/#{TEST_PACKAGE}/version"))
        .with { |req| JSON.parse(req.body)["ageLegal"] == "12+" }
    end

    it "rejects unknown age_legal value" do
      expect { lane_with("age_legal: '10+'") }
        .to raise_error(FastlaneCore::Interface::FastlaneError, /age_legal/)
    end
  end

  describe "draft metadata — descriptions and price" do
    before { stub_full_workflow }

    def lane_with(params_extra)
      Fastlane::FastFile.new.parse(<<~LANE).runner.execute(:test)
        lane :test do
          rustore_upload(
            package_name: '#{TEST_PACKAGE}',
            key_id:       'test-key',
            private_key:  #{rsa_pem.inspect},
            aab_path:     '#{aab_file.path}',
            #{params_extra}
          )
        end
      LANE
    end

    it "sends short_description as shortDescription" do
      lane_with("short_description: 'A great app'")
      expect(WebMock).to have_requested(:post, api("application/#{TEST_PACKAGE}/version"))
        .with { |req| JSON.parse(req.body)["shortDescription"] == "A great app" }
    end

    it "rejects short_description longer than 80 chars" do
      expect { lane_with("short_description: '#{"x" * 81}'") }
        .to raise_error(FastlaneCore::Interface::FastlaneError, /short_description.*80/)
    end

    it "sends full_description as fullDescription" do
      lane_with("full_description: 'Full text'")
      expect(WebMock).to have_requested(:post, api("application/#{TEST_PACKAGE}/version"))
        .with { |req| JSON.parse(req.body)["fullDescription"] == "Full text" }
    end

    it "rejects full_description longer than 4000 chars" do
      expect { lane_with("full_description: '#{"x" * 4001}'") }
        .to raise_error(FastlaneCore::Interface::FastlaneError, /full_description.*4000/)
    end

    it "sends price_value as priceValue" do
      lane_with("price_value: '8799'")
      expect(WebMock).to have_requested(:post, api("application/#{TEST_PACKAGE}/version"))
        .with { |req| JSON.parse(req.body)["priceValue"] == "8799" }
    end

    it "rejects non-digit price_value" do
      expect { lane_with("price_value: '87.99'") }
        .to raise_error(FastlaneCore::Interface::FastlaneError, /price_value.*digits/)
    end
  end

  describe "draft metadata — primitive arrays" do
    before { stub_full_workflow }

    def lane_with(params_extra)
      Fastlane::FastFile.new.parse(<<~LANE).runner.execute(:test)
        lane :test do
          rustore_upload(
            package_name: '#{TEST_PACKAGE}',
            key_id:       'test-key',
            private_key:  #{rsa_pem.inspect},
            aab_path:     '#{aab_file.path}',
            #{params_extra}
          )
        end
      LANE
    end

    it "sends categories as a JSON array" do
      lane_with("categories: ['news', 'education']")
      expect(WebMock).to have_requested(:post, api("application/#{TEST_PACKAGE}/version"))
        .with { |req| JSON.parse(req.body)["categories"] == ["news", "education"] }
    end

    it "rejects more than 2 categories" do
      expect { lane_with("categories: ['a', 'b', 'c']") }
        .to raise_error(FastlaneCore::Interface::FastlaneError, /categories.*2/)
    end

    it "rejects non-string elements in categories" do
      expect { lane_with("categories: ['a', 42]") }
        .to raise_error(FastlaneCore::Interface::FastlaneError, /categories/)
    end

    it "sends seo_tag_ids as seoTagIds" do
      lane_with("seo_tag_ids: [1, 2, 3]")
      expect(WebMock).to have_requested(:post, api("application/#{TEST_PACKAGE}/version"))
        .with { |req| JSON.parse(req.body)["seoTagIds"] == [1, 2, 3] }
    end

    it "rejects more than 5 seo_tag_ids" do
      expect { lane_with("seo_tag_ids: [1, 2, 3, 4, 5, 6]") }
        .to raise_error(FastlaneCore::Interface::FastlaneError, /seo_tag_ids.*5/)
    end

    it "rejects non-integer seo_tag_ids elements" do
      expect { lane_with("seo_tag_ids: [1, 'two']") }
        .to raise_error(FastlaneCore::Interface::FastlaneError, /seo_tag_ids.*integer/)
    end
  end

  describe "draft metadata — faq" do
    before { stub_full_workflow }

    def lane_with(params_extra)
      Fastlane::FastFile.new.parse(<<~LANE).runner.execute(:test)
        lane :test do
          rustore_upload(
            package_name: '#{TEST_PACKAGE}',
            key_id:       'test-key',
            private_key:  #{rsa_pem.inspect},
            aab_path:     '#{aab_file.path}',
            #{params_extra}
          )
        end
      LANE
    end

    it "sends faq as a JSON array of {question, answer} objects" do
      lane_with("faq: [{ question: 'Q1', answer: 'A1' }, { question: 'Q2', answer: 'A2' }]")
      expect(WebMock).to have_requested(:post, api("application/#{TEST_PACKAGE}/version"))
        .with { |req|
          JSON.parse(req.body)["faq"] == [
            { "question" => "Q1", "answer" => "A1" },
            { "question" => "Q2", "answer" => "A2" }
          ]
        }
    end

    it "rejects more than 10 items" do
      huge = "[" + (Array.new(11) { "{ question: 'q', answer: 'a' }" }.join(",")) + "]"
      expect { lane_with("faq: #{huge}") }
        .to raise_error(FastlaneCore::Interface::FastlaneError, /faq.*10/)
    end

    it "rejects an item without :question" do
      expect { lane_with("faq: [{ answer: 'a' }]") }
        .to raise_error(FastlaneCore::Interface::FastlaneError, /question/)
    end

    it "rejects question longer than 120 chars" do
      long_q = "x" * 121
      expect { lane_with("faq: [{ question: '#{long_q}', answer: 'a' }]") }
        .to raise_error(FastlaneCore::Interface::FastlaneError, /question.*120/)
    end

    it "rejects answer longer than 500 chars" do
      long_a = "y" * 501
      expect { lane_with("faq: [{ question: 'q', answer: '#{long_a}' }]") }
        .to raise_error(FastlaneCore::Interface::FastlaneError, /answer.*500/)
    end
  end

  describe "draft metadata — full v2 coverage" do
    before { stub_full_workflow }

    it "sends every v2 field with the correct camelCase key" do
      Fastlane::FastFile.new.parse(<<~LANE).runner.execute(:test)
        lane :test do
          rustore_upload(
            package_name:       '#{TEST_PACKAGE}',
            key_id:             'test-key',
            private_key:        #{rsa_pem.inspect},
            aab_path:           '#{aab_file.path}',
            whats_new:          'Notes',
            developer_contacts: { email: 'a@b.c', website: 'https://x.io', vk_community: 'https://vk.com/x' },
            app_name:           'My App',
            app_type:           'MAIN',
            categories:         ['news', 'education'],
            age_legal:          '0+',
            short_description:  'Short',
            full_description:   'Full text',
            price_value:        '8799',
            seo_tag_ids:        [1, 2, 3],
            faq:                [{ question: 'Q', answer: 'A' }]
          )
        end
      LANE

      expect(WebMock).to have_requested(:post, api("application/#{TEST_PACKAGE}/version"))
        .with { |req|
          body = JSON.parse(req.body)
          body["developerContacts"] == { "email" => "a@b.c", "website" => "https://x.io", "vkCommunity" => "https://vk.com/x" } &&
            body["appName"]          == "My App" &&
            body["appType"]          == "MAIN" &&
            body["categories"]       == ["news", "education"] &&
            body["ageLegal"]         == "0+" &&
            body["shortDescription"] == "Short" &&
            body["fullDescription"]  == "Full text" &&
            body["priceValue"]       == "8799" &&
            body["seoTagIds"]        == [1, 2, 3] &&
            body["faq"]              == [{ "question" => "Q", "answer" => "A" }] &&
            body["whatsNew"]         == "Notes" &&
            body["publishType"]      == "INSTANTLY"
        }
    end
  end
end
