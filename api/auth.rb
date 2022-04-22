module AdminApi
  class Auth < ::Grape::API
    params do
      optional :message, type: String
    end
    get "/login" do
      erb("login")
    end

    params do
      requires :depot_user, type: Hash do
        requires :email, type: String, desc: "Depot User's email."
        requires :password, type: String, desc: "Depot User's LAS pin number"
      end
    end
    post "/login" do
      # This is copied from the /auths API
      pw_auth_user = Nda::AuthClient.pw_login(params)
      user = ::User.find_by(email: pw_auth_user[:email])
      if user&.is_admin
        user.update(pw_token: pw_auth_user[:token], name: pw_auth_user[:name])
        cookies[:token] = {value: pw_auth_user[:token], expires: Time.now + Root::TOKEN_REFRESH}
        redirect "/admin/users?message=User%20successfully%20logged%20in"
      else
        redirect "/admin/login?message=User%20lacking%20admin%20rights"
      end
    rescue AuthServerError
      redirect "/admin/login?message=Invalid%20username%20or%20password"
    rescue Errno::ECONNREFUSED
      redirect "/admin/login?message=Error%20connecting%20to%20PerfectWard"
    end

    get "/logout" do
      cookies.delete :token
      redirect "/admin/login"
    end
  end
end
