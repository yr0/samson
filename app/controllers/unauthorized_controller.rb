# frozen_string_literal: true
class UnauthorizedController < ActionController::Metal
  include ActionController::UrlFor
  include ActionController::Redirecting

  include AbstractController::Rendering
  include ActionController::Rendering
  include ActionController::Renderers::All
  include ActionController::ConditionalGet
  include ActionController::MimeResponds

  include Rails.application.routes.url_helpers

  delegate :flash, to: :request

  def self.call(env)
    action(:respond).call(env)
  end

  def respond
    if request.path.start_with?('/api/') || request.format == :json
      render json: {}, status: 404
    else
      respond_to do |format|
        format.html do
          flash[:authorization_error] = "You are not authorized to view this page."
          redirect_back_or(login_path)
        end
      end
    end
  end

  private

  def redirect_back_or(path)
    redirect_back fallback_location: path
  end
end
