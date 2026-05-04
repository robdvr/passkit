module Passkit
  class Pass < ActiveRecord::Base
    validates_uniqueness_of :serial_number
    validates_presence_of :klass

    belongs_to :generator, polymorphic: true, optional: true
    has_many :registrations, foreign_key: :passkit_pass_id
    has_many :devices, through: :registrations

    delegate :accessibility_url,
      :additional_info_fields,
      :add_on_url,
      :apple_team_identifier,
      :app_launch_url,
      :associated_store_identifiers,
      :auxiliary_fields,
      :auxiliary_store_identifiers,
      :back_fields,
      :background_color,
      :bag_policy_url,
      :barcode,
      :barcodes,
      :beacons,
      :boarding_pass,
      :contact_venue_email,
      :contact_venue_phone_number,
      :contact_venue_website,
      :description,
      :directions_information_url,
      :event_logo_text,
      :expiration_date,
      :file_name,
      :footer_background_color,
      :foreground_color,
      :format_version,
      :grouping_identifier,
      :header_fields,
      :label_color,
      :language,
      :localized_strings,
      :locations,
      :logo_text,
      :max_distance,
      :merchandise_url,
      :nfc,
      :order_food_url,
      :organization_name,
      :parking_information_url,
      :pass_path,
      :pass_type,
      :pass_type_identifier,
      :preferred_style_schemes,
      :primary_fields,
      :purchase_parking_url,
      :relevant_date,
      :relevant_dates,
      :secondary_fields,
      :sell_url,
      :semantics,
      :sharing_prohibited,
      :suppress_strip_shine,
      :transfer_url,
      :transit_information_url,
      :use_automatic_colors,
      :user_info,
      :voided,
      :web_service_url,
      to: :instance

    before_validation on: :create do
      self.authentication_token ||= SecureRandom.hex
      self.serial_number ||= SecureRandom.uuid
    end

    # `klass` is captured from the encrypted URL payload at create time and
    # constantized here so the AR row can act as a façade over the subclass.
    # The controller's `allowed_pass_class?` guard is the only thing standing
    # between an attacker-controlled string and `constantize`, so configuring
    # `Passkit.configuration.pass_classes` with the host app's known pass
    # subclasses is strongly recommended (an empty allowlist disables the
    # check for backward compatibility).
    def instance
      @instance ||= klass.constantize.new(generator)
    end

    def last_update
      instance.last_update || updated_at
    end
  end
end
