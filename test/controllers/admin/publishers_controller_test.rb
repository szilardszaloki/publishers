require 'test_helper'
require "webmock/minitest"

class Admin::PublishersControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  def stub_verification_public_file(channel, body: nil, status: 200)
    url = "https://#{channel.details.brave_publisher_id}/.well-known/brave-payments-verification.txt"
    headers = {
      'Accept' => '*/*',
      'Accept-Encoding' => 'gzip;q=1.0,deflate;q=0.6,identity;q=0.3',
      'Host' => channel.details.brave_publisher_id,
      'User-Agent' => 'Ruby'
    }
    body ||= SiteChannelVerificationFileGenerator.new(site_channel: channel).generate_file_content
    stub_request(:get, url).
      with(headers: headers).
      to_return(status: status, body: body, headers: {})
  end

  test "regular users cannot access" do
    publisher = publishers(:completed)
    sign_in publisher

    assert_raises(CanCan::AccessDenied) {
      get admin_publishers_path
    }
  end

  test "admin can access" do
    admin = publishers(:admin)
    sign_in admin

    get admin_publishers_path
    assert_response :success
  end

  test "admin filters appropriately on name & email" do
    admin = publishers(:admin)
    publisher = publishers(:completed)
    sign_in admin

    get admin_publishers_path
    assert_response :success
    assert_select 'tbody' do
      assert_select 'tr' do
        assert_select 'td', publisher.id
      end
    end

    get admin_publishers_path, params: {q: "#{publisher.name}"}
    assert_response :success
    assert_select 'tbody' do
      assert_select 'tr', true
    end

    get admin_publishers_path, params: {q: "#{publisher.name}failure"}
    assert_response :success
    assert_select 'tbody' do
      assert_select 'tr', false
    end
  end

  test "raises error unless admin has 2fa enabled" do
    admin = publishers(:admin)
    admin.totp_registration.destroy! # remove 2fa
    admin.reload
    sign_in admin

    assert_raises(Ability::TwoFactorDisabledError) do
      get admin_publishers_path
    end
  end

  test "raises error unless admin is on admin whitelist" do
    admin = publishers(:admin)
    sign_in admin

    assert_raises(Ability::AdminNotOnIPWhitelistError) do
      get admin_publishers_path, headers: { 'REMOTE_ADDR' => '1.2.3.4' } # not on whitelist
    end
  end

  test "statements created by admin have created_by_admin flag" do
    admin = publishers(:admin)
    publisher = publishers(:uphold_connected)
    sign_in admin

    prev_total_publisher_statements = PublisherStatement.count
    
    patch generate_statement_admin_publishers_path(id: publisher.id, statement_period: :past_7_days)

    # ensure a statement is created
    assert PublisherStatement.count == prev_total_publisher_statements + 1

    created_statement = PublisherStatement.order("created_at").last

    # ensure it has the created by admin flag
    assert created_statement.created_by_admin
  end

  test "admins can approve channels waiting for admin approval" do
    admin = publishers(:admin)
    c = channels(:to_verify_restricted)
    stub_verification_public_file(c)

    # simulate verification attempt that will be blocked
    verifier = SiteChannelVerifier.new(channel: c)
    verifier.perform
    c.reload
    assert c.verification_awaiting_admin_approval?

    # simulate admin approving channel
    sign_in admin
    patch approve_channel_admin_publishers_path(channel_id: c.id)
    c.reload
    assert c.verified?
    assert c.verification_approved_by_admin?
  end
end
