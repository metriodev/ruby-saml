require File.expand_path(File.join(File.dirname(__FILE__), "test_helper"))

require 'onelogin/ruby-saml/logoutrequest'

class RequestTest < Minitest::Test

  describe "Logoutrequest" do
    let(:settings) { OneLogin::RubySaml::Settings.new }

    before do
      settings.idp_slo_target_url = "http://unauth.com/logout"
      settings.name_identifier_value = "f00f00"
    end

    it "create the deflated SAMLRequest URL parameter" do
      unauth_url = OneLogin::RubySaml::Logoutrequest.new.create(settings)
      assert unauth_url =~ /^http:\/\/unauth\.com\/logout\?SAMLRequest=/

      inflated = decode_saml_request_payload(unauth_url)

      assert_match /^<samlp:LogoutRequest/, inflated
    end

    it "support additional params" do
      unauth_url = OneLogin::RubySaml::Logoutrequest.new.create(settings, { :hello => nil })
      assert unauth_url =~ /&hello=$/

      unauth_url = OneLogin::RubySaml::Logoutrequest.new.create(settings, { :foo => "bar" })
      assert unauth_url =~ /&foo=bar$/
    end

    it "set sessionindex" do
      sessionidx = UUID.new.generate
      settings.sessionindex = sessionidx

      unauth_url = OneLogin::RubySaml::Logoutrequest.new.create(settings, { :name_id => "there" })
      inflated = decode_saml_request_payload(unauth_url)

      assert_match /<samlp:SessionIndex/, inflated
      assert_match %r(#{sessionidx}</samlp:SessionIndex>), inflated
    end

    it "set name_identifier_value" do
      settings.name_identifier_format = "transient"
      name_identifier_value = "abc123"
      settings.name_identifier_value = name_identifier_value

      unauth_url = OneLogin::RubySaml::Logoutrequest.new.create(settings, { :name_id => "there" })
      inflated = decode_saml_request_payload(unauth_url)

      assert_match /<saml:NameID/, inflated
      assert_match %r(#{name_identifier_value}</saml:NameID>), inflated
    end

    describe "when the target url doesn't contain a query string" do
      it "create the SAMLRequest parameter correctly" do
        settings.idp_slo_target_url = "http://example.com"

        unauth_url = OneLogin::RubySaml::Logoutrequest.new.create(settings)
        assert unauth_url =~ /^http:\/\/example.com\?SAMLRequest/
      end
    end

    describe "when the target url contains a query string" do
      it "create the SAMLRequest parameter correctly" do
        settings.idp_slo_target_url = "http://example.com?field=value"

        unauth_url = OneLogin::RubySaml::Logoutrequest.new.create(settings)
        assert unauth_url =~ /^http:\/\/example.com\?field=value&SAMLRequest/
      end
    end

    describe "consumation of logout may need to track the transaction" do
      it "have access to the request uuid" do
        unauth_req = OneLogin::RubySaml::Logoutrequest.new
        unauth_url = unauth_req.create(settings)

        inflated = decode_saml_request_payload(unauth_url)
        assert_match %r[ID='#{unauth_req.uuid}'], inflated
      end
    end

    describe "when the settings indicate to sign (embedded) logout request" do

      let(:settings2) { OneLogin::RubySaml::Settings.new }

      before do
        settings2.idp_slo_target_url = "http://example.com?field=value"
        settings2.name_identifier_value = "f00f00"
        # sign the logout request
        settings2.security[:logout_requests_signed] = true
        settings2.security[:embed_sign] = true
        settings2.certificate = ruby_saml_cert_text
        settings2.private_key = ruby_saml_key_text
      end

      it "created a signed logout request" do
        settings2.compress_request = true

        unauth_req = OneLogin::RubySaml::Logoutrequest.new
        unauth_url = unauth_req.create(settings2)

        inflated = decode_saml_request_payload(unauth_url)
        assert_match %r[<ds:SignatureValue>([a-zA-Z0-9/+=]+)</ds:SignatureValue>], inflated
        assert_match %r[<ds:SignatureMethod Algorithm='http://www.w3.org/2000/09/xmldsig#rsa-sha1'/>], inflated
        assert_match %r[<ds:DigestMethod Algorithm='http://www.w3.org/2000/09/xmldsig#sha1'/>], inflated
      end

      it "create a signed logout request with 256 digest and signature methods" do
        settings2.compress_request = false
        settings2.security[:signature_method] = XMLSecurity::Document::RSA_SHA256
        settings2.security[:digest_method] = XMLSecurity::Document::SHA512

        params = OneLogin::RubySaml::Logoutrequest.new.create_params(settings2)
        request_xml = Base64.decode64(params["SAMLRequest"])

        assert_match %r[<ds:SignatureValue>([a-zA-Z0-9/+=]+)</ds:SignatureValue>], request_xml
        assert_match %r[<ds:SignatureMethod Algorithm='http://www.w3.org/2001/04/xmldsig-more#rsa-sha256'/>], request_xml
        assert_match %r[<ds:DigestMethod Algorithm='http://www.w3.org/2001/04/xmldsig-more#sha512'/>], request_xml
      end
    end

    describe "#create_params when the settings indicate to sign the logout request" do

      let(:settings3) { OneLogin::RubySaml::Settings.new }
      let(:cert)      { OpenSSL::X509::Certificate.new(ruby_saml_cert_text) }

      before do
        settings3.idp_slo_target_url = "http://example.com?field=value"
        settings3.name_identifier_value = "f00f00"
        # sign the logout request
        settings3.security[:logout_requests_signed] = true
        settings3.security[:embed_sign] = false
        settings3.certificate = ruby_saml_cert_text
        settings3.private_key = ruby_saml_key_text
      end

      it "create a signature parameter with RSA_SHA1 and validate it" do
        settings.security[:signature_method] = XMLSecurity::Document::RSA_SHA1

        params = OneLogin::RubySaml::Logoutrequest.new.create_params(settings3, :RelayState => 'http://example.com')
        assert params['SAMLRequest']
        assert params[:RelayState]
        assert params['Signature']
        assert_equal params['SigAlg'], XMLSecurity::Document::RSA_SHA1

        query_string = "SAMLRequest=#{CGI.escape(params['SAMLRequest'])}"
        query_string << "&RelayState=#{CGI.escape(params[:RelayState])}"
        query_string << "&SigAlg=#{CGI.escape(params['SigAlg'])}"

        signature_algorithm = XMLSecurity::BaseDocument.new.algorithm(params['SigAlg'])
        assert_equal signature_algorithm, OpenSSL::Digest::SHA1
        assert cert.public_key.verify(signature_algorithm.new, Base64.decode64(params['Signature']), query_string)
      end

      it "create a signature parameter with RSA_SHA256 and validate it" do
        settings3.security[:signature_method] = XMLSecurity::Document::RSA_SHA256

        params = OneLogin::RubySaml::Logoutrequest.new.create_params(settings3, :RelayState => 'http://example.com')
        assert params['Signature']
        assert_equal params['SigAlg'], XMLSecurity::Document::RSA_SHA256

        query_string = "SAMLRequest=#{CGI.escape(params['SAMLRequest'])}"
        query_string << "&RelayState=#{CGI.escape(params[:RelayState])}"
        query_string << "&SigAlg=#{CGI.escape(params['SigAlg'])}"

        signature_algorithm = XMLSecurity::BaseDocument.new.algorithm(params['SigAlg'])
        assert_equal signature_algorithm, OpenSSL::Digest::SHA256 
        assert cert.public_key.verify(signature_algorithm.new, Base64.decode64(params['Signature']), query_string) 
      end

    end
  end
end
