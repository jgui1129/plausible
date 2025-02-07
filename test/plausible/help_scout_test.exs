defmodule Plausible.HelpScoutTest do
  use Plausible.DataCase, async: true
  use Plausible

  @moduletag :ee_only

  on_ee do
    alias Plausible.Billing.Subscription
    alias Plausible.HelpScout
    alias Plausible.Repo

    require Plausible.Billing.Subscription.Status

    @v4_business_monthly_plan_id "857105"
    @v4_business_yearly_plan_id "857087"

    describe "validate_signature/1" do
      test "returns error on missing signature" do
        conn =
          :get
          |> Plug.Test.conn("/?foo=one&bar=two&baz=three")
          |> Plug.Conn.fetch_query_params()

        assert {:error, :missing_signature} = HelpScout.validate_signature(conn)
      end

      test "returns error on invalid signature" do
        conn =
          :get
          |> Plug.Test.conn("/?foo=one&bar=two&baz=three&X-HelpScout-Signature=invalid")
          |> Plug.Conn.fetch_query_params()

        assert {:error, :bad_signature} = HelpScout.validate_signature(conn)
      end

      test "passes for valid signature" do
        signature_key = Application.fetch_env!(:plausible, HelpScout)[:signature_key]
        data = ~s|{"foo":"one","bar":"two","baz":"three"}|

        signature =
          :hmac
          |> :crypto.mac(:sha, signature_key, data)
          |> Base.encode64()
          |> URI.encode_www_form()

        conn =
          :get
          |> Plug.Test.conn("/?foo=one&bar=two&baz=three&X-HelpScout-Signature=#{signature}")
          |> Plug.Conn.fetch_query_params()

        assert :ok = HelpScout.validate_signature(conn)
      end
    end

    describe "get_customer_details/1" do
      test "returns details for user on trial" do
        %{id: user_id, email: email} = insert(:user)
        stub_help_scout_requests(email)

        crm_url = "#{PlausibleWeb.Endpoint.url()}/crm/auth/user/#{user_id}"

        assert {:ok,
                %{
                  status_link: ^crm_url,
                  status_label: "Trial",
                  plan_link: "#",
                  plan_label: "None"
                }} = HelpScout.get_customer_details("500")
      end

      test "returns for user without trial or subscription" do
        %{email: email} = insert(:user, trial_expiry_date: nil)
        stub_help_scout_requests(email)

        assert {:ok,
                %{
                  status_link: _,
                  status_label: "None",
                  plan_link: "#",
                  plan_label: "None"
                }} = HelpScout.get_customer_details("500")
      end

      test "returns for user with trial expired" do
        %{email: email} = insert(:user, trial_expiry_date: Date.add(Date.utc_today(), -1))
        stub_help_scout_requests(email)

        assert {:ok,
                %{
                  status_link: _,
                  status_label: "Expired trial",
                  plan_link: "#",
                  plan_label: "None"
                }} = HelpScout.get_customer_details("500")
      end

      test "returns for user with paid subscription on standard plan" do
        user = %{email: email} = insert(:user, trial_expiry_date: Date.add(Date.utc_today(), -1))

        %{paddle_subscription_id: paddle_subscription_id} =
          insert(:subscription, user: user, paddle_plan_id: @v4_business_monthly_plan_id)

        stub_help_scout_requests(email)

        plan_link =
          "https://vendors.paddle.com/subscriptions/customers/manage/#{paddle_subscription_id}"

        assert {:ok,
                %{
                  status_link: _,
                  status_label: "Paid",
                  plan_link: ^plan_link,
                  plan_label: "10k Plan (€10 monthly)"
                }} = HelpScout.get_customer_details("500")
      end

      test "returns for user with paid subscription on standard yearly plan" do
        user = %{email: email} = insert(:user, trial_expiry_date: Date.add(Date.utc_today(), -1))

        %{paddle_subscription_id: paddle_subscription_id} =
          insert(:subscription, user: user, paddle_plan_id: @v4_business_yearly_plan_id)

        stub_help_scout_requests(email)

        plan_link =
          "https://vendors.paddle.com/subscriptions/customers/manage/#{paddle_subscription_id}"

        assert {:ok,
                %{
                  status_link: _,
                  status_label: "Paid",
                  plan_link: ^plan_link,
                  plan_label: "10k Plan (€100 yearly)"
                }} = HelpScout.get_customer_details("500")
      end

      test "returns for user with paid subscription on free 10k plan" do
        user = %{email: email} = insert(:user, trial_expiry_date: Date.add(Date.utc_today(), -1))

        insert(:subscription, user: user, paddle_plan_id: "free_10k")

        stub_help_scout_requests(email)

        assert {:ok,
                %{
                  status_link: _,
                  status_label: "Paid",
                  plan_link: _,
                  plan_label: "Free 10k"
                }} = HelpScout.get_customer_details("500")
      end

      test "returns for user with paid subscription on enterprise plan" do
        user = %{email: email} = insert(:user, trial_expiry_date: Date.add(Date.utc_today(), -1))

        ep =
          insert(:enterprise_plan,
            features: [Plausible.Billing.Feature.StatsAPI],
            user_id: user.id
          )

        insert(:subscription, user: user, paddle_plan_id: ep.paddle_plan_id)

        stub_help_scout_requests(email)

        assert {:ok,
                %{
                  status_link: _,
                  status_label: "Paid",
                  plan_link: _,
                  plan_label: "1M Enterprise Plan (€10 monthly)"
                }} = HelpScout.get_customer_details("500")
      end

      test "returns for user with paid subscription on yearly enterprise plan" do
        user = %{email: email} = insert(:user, trial_expiry_date: Date.add(Date.utc_today(), -1))

        ep =
          insert(:enterprise_plan,
            features: [Plausible.Billing.Feature.StatsAPI],
            user_id: user.id,
            billing_interval: :yearly
          )

        insert(:subscription, user: user, paddle_plan_id: ep.paddle_plan_id)

        stub_help_scout_requests(email)

        assert {:ok,
                %{
                  status_link: _,
                  status_label: "Paid",
                  plan_link: _,
                  plan_label: "1M Enterprise Plan (€10 yearly)"
                }} = HelpScout.get_customer_details("500")
      end

      test "returns for user with subscription pending cancellation" do
        user = %{email: email} = insert(:user, trial_expiry_date: Date.add(Date.utc_today(), -1))

        insert(:subscription,
          user: user,
          status: Subscription.Status.deleted(),
          paddle_plan_id: @v4_business_monthly_plan_id
        )

        stub_help_scout_requests(email)

        assert {:ok,
                %{
                  status_link: _,
                  status_label: "Pending cancellation",
                  plan_link: _,
                  plan_label: "10k Plan (€10 monthly)"
                }} = HelpScout.get_customer_details("500")
      end

      test "returns for user with canceled subscription" do
        user = %{email: email} = insert(:user, trial_expiry_date: Date.add(Date.utc_today(), -1))

        insert(:subscription,
          user: user,
          status: Subscription.Status.deleted(),
          paddle_plan_id: @v4_business_monthly_plan_id,
          next_bill_date: Date.add(Date.utc_today(), -1)
        )

        stub_help_scout_requests(email)

        assert {:ok,
                %{
                  status_link: _,
                  status_label: "Canceled",
                  plan_link: _,
                  plan_label: "10k Plan (€10 monthly)"
                }} = HelpScout.get_customer_details("500")
      end

      test "returns for user with paused subscription" do
        user = %{email: email} = insert(:user, trial_expiry_date: Date.add(Date.utc_today(), -1))

        insert(:subscription,
          user: user,
          status: Subscription.Status.paused(),
          paddle_plan_id: @v4_business_monthly_plan_id
        )

        stub_help_scout_requests(email)

        assert {:ok,
                %{
                  status_link: _,
                  status_label: "Paused",
                  plan_link: _,
                  plan_label: "10k Plan (€10 monthly)"
                }} = HelpScout.get_customer_details("500")
      end

      test "returns for user with locked site" do
        user = %{email: email} = insert(:user, trial_expiry_date: Date.add(Date.utc_today(), -1))

        insert(:site, members: [user], locked: true)

        insert(:subscription, user: user, paddle_plan_id: @v4_business_monthly_plan_id)

        stub_help_scout_requests(email)

        assert {:ok,
                %{
                  status_link: _,
                  status_label: "Dashboard locked",
                  plan_link: _,
                  plan_label: "10k Plan (€10 monthly)"
                }} = HelpScout.get_customer_details("500")
      end

      test "returns error when no matching user found in database" do
        insert(:user)

        stub_help_scout_requests("another@example.com")

        assert {:error, :not_found} = HelpScout.get_customer_details("500")
      end

      test "returns error when no customer found in Help Scout" do
        Req.Test.stub(HelpScout, fn
          %{request_path: "/v2/oauth2/token"} = conn ->
            Req.Test.json(conn, %{
              "token_type" => "bearer",
              "access_token" => "369dbb08be58430086d2f8bd832bc1eb",
              "expires_in" => 172_800
            })

          %{request_path: "/v2/customers/500"} = conn ->
            conn
            |> Plug.Conn.put_status(404)
            |> Req.Test.text("Not found")
        end)

        assert {:error, :not_found} = HelpScout.get_customer_details("500")
      end

      test "returns error when found customer has no emails" do
        Req.Test.stub(HelpScout, fn
          %{request_path: "/v2/oauth2/token"} = conn ->
            Req.Test.json(conn, %{
              "token_type" => "bearer",
              "access_token" => "369dbb08be58430086d2f8bd832bc1eb",
              "expires_in" => 172_800
            })

          %{request_path: "/v2/customers/500"} = conn ->
            Req.Test.json(conn, %{
              "id" => 500,
              "_embedded" => %{
                "emails" => []
              }
            })
        end)

        assert {:error, :no_emails} = HelpScout.get_customer_details("500")
      end

      test "uses existing access token when available" do
        %{email: email} = insert(:user)
        now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

        Repo.insert_all("help_scout_credentials", [
          [
            access_token: HelpScout.Vault.encrypt!("VerySecret"),
            inserted_at: now,
            updated_at: now
          ]
        ])

        Req.Test.stub(HelpScout, fn %{request_path: "/v2/customers/500"} = conn ->
          Req.Test.json(conn, %{
            "id" => 500,
            "_embedded" => %{
              "emails" => [
                %{
                  "id" => 1,
                  "value" => email,
                  "type" => "home"
                }
              ]
            }
          })
        end)

        assert {:ok, _} = HelpScout.get_customer_details("500")
      end

      test "refreshes token on expiry" do
        %{email: email} = insert(:user)
        now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

        Repo.insert_all("help_scout_credentials", [
          [
            access_token: HelpScout.Vault.encrypt!("VerySecretExpired"),
            inserted_at: now,
            updated_at: now
          ]
        ])

        Req.Test.stub(HelpScout, fn
          %{request_path: "/v2/oauth2/token"} = conn ->
            Req.Test.json(conn, %{
              "token_type" => "bearer",
              "access_token" => "VerySecretNew",
              "expires_in" => 172_800
            })

          %{request_path: "/v2/customers/500"} = conn ->
            case Plug.Conn.get_req_header(conn, "authorization") do
              ["Bearer VerySecretExpired"] ->
                conn
                |> Plug.Conn.put_status(401)
                |> Req.Test.text("Token expired")

              ["Bearer VerySecretNew"] ->
                Req.Test.json(conn, %{
                  "id" => 500,
                  "_embedded" => %{
                    "emails" => [
                      %{
                        "id" => 1,
                        "value" => email,
                        "type" => "home"
                      }
                    ]
                  }
                })
            end
        end)

        assert {:ok, _} = HelpScout.get_customer_details("500")
      end
    end

    defp stub_help_scout_requests(email) do
      Req.Test.stub(HelpScout, fn
        %{request_path: "/v2/oauth2/token"} = conn ->
          Req.Test.json(conn, %{
            "token_type" => "bearer",
            "access_token" => "369dbb08be58430086d2f8bd832bc1eb",
            "expires_in" => 172_800
          })

        %{request_path: "/v2/customers/500"} = conn ->
          Req.Test.json(conn, %{
            "id" => 500,
            "_embedded" => %{
              "emails" => [
                %{
                  "id" => 1,
                  "value" => email,
                  "type" => "home"
                }
              ]
            }
          })
      end)
    end
  end
end
