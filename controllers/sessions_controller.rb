class SessionsController < ApplicationController
  skip_before_action :verify_authenticity_token
  skip_before_action :check_token

  def new

  end

  def create
    pw_auth_user = Nda::AuthClient.pw_login(user_params)
    user = ::User.find_by(email: pw_auth_user[:email])
    if user.is_depot_personnel
      user.update(pw_token: pw_auth_user[:token], name: pw_auth_user[:name])
      cookies[:token] = {value: pw_auth_user[:token], expires: Time.now + Root::TOKEN_REFRESH}
      redirect_to main_path
    else
      flash.now[:error] = "Incorrect email or password."
      redirect_to login_path
    end
  rescue AuthServerError
    flash[:error] = "Invalid username or password!"
    redirect_to login_path
  rescue Errno::ECONNREFUSED
    flash[:error] = "Error connecting to PerfectWard"
    redirect_to login_path
  end

  def destroy
    cookies.delete :token
    redirect_to root_path, notice: "Signed out."
  end

  def user_params
    params.permit(depot_user: [:email, :password])
  end
end
