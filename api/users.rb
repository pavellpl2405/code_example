module Api::V1
  class Users < ::Grape::API
    do_not_route_head!

    # v1/users
    resource :users do
      helpers Api::V1::Helpers::SharedParams

      # POST v1/users
      desc "Create a new User."
      params do
        requires :access_token, type: String, desc: "Access Token with create_pack rights (TBD)."
        requires :data, type: File
      end
      post "/" do
        status 201
        ::User.import_data(params[:data][:tempfile])
      end

      # GET v1/users
      desc "List all users viewable by the current_user."
      params do
        requires :access_token, type: String, desc: "Access Token with create_pack rights (TBD)."
        use :pagination
        optional :q, type: String, desc: ""
        optional :with # NOT IN USE FOR THE MOMENT
        optional :filters, type: Hash do
          # NOT IN USE FOR NOW
        end
      end
      get "/" do
        status 200
        present User.list(params, current_user), with: Entities::UserList # , for: params[:for].to_sym
      end

      # v1/users/{:user_id} endpoints
      route_param :user_id, requirements: {user_id: /[0-9]*/} do
        # helper method to get the specified User
        helpers do
          def user
            User.find(params[:user_id])
          end
        end

        # GET v1/users/{:user_id}
        desc "View {user_id}'s attributes"
        params do
          requires :access_token, type: String, desc: "Access Token for accessing {user_id}'s attributes.", documentation: {example: "abc123"}
        end
        get "/" do
          status 200
          present user, with: Entities::User
        end

        # PUT v1/users/{:user_id}
        desc "Update {user_id}'s attributes"
        params do
          requires :access_token, type: String, desc: "Access Token with update_pack rights (TBD)."
          requires :user, type: Hash do
          end
        end
        put "/" do
          status 200
          present user, with: Entities::User
        end

        # DELETE v1/users/{:user_id}
        desc "Delete {user_id}'s attributes"
        params do
          requires :access_token, type: String, desc: "Access Token with delete_pack rights.", documentation: {example: "abc123"}
        end
        delete "/" do
          status 204
        end

        # ----------------------------------------------------------------
        # ------------ User related actions for Packs ---------------
        # ----------------------------------------------------------------

        # GET v1/users/{:user_id}/actions
        desc "View all actions created by {:user_id}."
        params do
          requires :access_token, type: String, desc: "Access Token for accessing {station_id}'s attributes.", documentation: {example: "abc123"}
          use :pagination
        end
        get "/actions" do
          status 200
          present ::PackAction.list({filters: {user_ids: [params[:user_id]]}, page: params[:page], per_page: params[:per_page]}), with: Entities::PackActionList, no_user: true
        end

        # GET v1/users/{:station_id}/packs
        desc "View all drug packs checked out by User {station_id}"
        params do
          requires :access_token, type: String, desc: "Access Token for accessing {station_id}'s attributes.", documentation: {example: "abc123"}
        end
        get "/drug_packs" do
          status 200
          # present PackAction.where(id: DrugPackAction.where(user_id: params[:user_id], action_id: 7).group(:drug_pack_id).maximum(:id).keys).map(&:drug_pack), with: Entities::DrugPackListItem
          "Endpoint to be revised!"
        end
      end
      # v1/users/{:user_id} endpoints
    end
    # v1/users
  end
end
