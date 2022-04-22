module Api::V1
  class Drugs < ::Grape::API
    do_not_route_head!

    # v1/drugs
    resource :drugs do
      helpers Api::V1::Helpers::SharedParams

      # GET v1/drugs/
      desc "List all drugs LAS uses."
      params do
        requires :access_token, type: String, desc: "Access Token for checking out pack.", documentation: {example: "abc123"}
        optional :filters, type: Hash do
          # NOT IN USE FOR NOW
          optional :drug_type, type: String, desc: "Filter drugs by their type.", values: ["station_based", "controlled", "non_drug"]
        end
      end
      get "/" do
        status 200
        present Drug.without_deleted.list(params, current_user), with: Entities::DrugList
      end

      # v1/drugs/{:drug_id} endpoints
      route_param :drug_id, requirements: {drug_id: /[0-9]*/} do
        # helper method to get the specified Drug
        helpers do
          def drug
            Drug.find(params[:drug_id])
          end
        end

        # GET v1/drugs/{:drug_id}/
        desc "Get {drug_id}'s details."
        params do
          requires :access_token, type: String, desc: "Access Token for accessing {drug_id}'s attributes.", documentation: {example: "abc123"}
        end
        get "/" do
          status 200
          present drug, with: Entities::Drug
        end

        # v1/drugs/{:drug_id}/batches endpoints
        resource :batches do
          # GET v1/drugs/{:drug_id}/batches
          desc "Get {drug_id}'s available batches."
          params do
            requires :access_token, type: String, desc: "Access Token for accessing {drug_id}'s attributes.", documentation: {example: "abc123"}
          end
          get "/" do
            status 200
            if is_depot_app
              inventory_batch_ids, inventory = drug.workstation_inventory_batches(associated_replenish_workstation)
              present ::Batch.list({filters: {ids: inventory_batch_ids, expiry_date: {from: Date.today}}}), with: Entities::BatchList, quantities: inventory
            else
              present ::Batch.list({filters: {drug_ids: [drug.id], expiry_date: {from: Date.today}}}), with: Entities::BatchList
            end
          end

          # POST v1/drugs/{:drug_id}/batches
          desc "Get {drug_id}'s available batches."
          params do
            requires :access_token, type: String, desc: "Access Token for accessing {drug_id}'s attributes.", documentation: {example: "abc123"}
            requires :batch, type: Hash do
              requires :batch_no, type: String, desc: "The Batch no."
              requires :expiry_date, type: DateTimeFromEpoch, desc: "The expiry date."
            end
          end
          post "/" do
            status 201
            present ::Batch.find_or_create_by(batch_params.merge!(drug_id: params[:drug_id])), with: Entities::BatchBase
          end

          # v1/drugs/{:drug_id}/batches/[:batch_id] endpoints
          route_param :batch_id, requirements: {batch_id: /[0-9]*/} do
            # helper method to get the specified Drug
            helpers do
              def batch
                ::Batch.find(params[:batch_id])
              end
            end

            # PUT v1/drugs/{:drug_id}/batches/[:batch_id]
            desc "Update {batch_id}'s expiry date."
            params do
              requires :access_token, type: String, desc: "Access Token for accessing {batch_id}'s attributes.", documentation: {example: "abc123"}
              requires :batch, type: Hash do
                requires :expiry_date, type: DateTimeFromEpoch, desc: "The new expiry date."
              end
            end
            put "/" do
              status 201
              raise Nda::Exceptions::InvalidRecord, "You don't have the required permissions to update the expiry date." unless ::Constant.user_roles.where(name: ["CTL", "IRO"]).map(&:id).include?(current_user.user_type_id)
              batch.update_attribute(:expiry_date, params[:batch][:expiry_date])
              present batch, with: Entities::BatchBase
            end
          end
        end
      end
    end
  end
end
