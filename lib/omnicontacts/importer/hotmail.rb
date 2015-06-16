require "omnicontacts/middleware/oauth2"
require "omnicontacts/parse_utils"
require "json"

module OmniContacts
  module Importer
    class Hotmail < Middleware::OAuth2
      include ParseUtils

      attr_reader :auth_host, :authorize_path, :auth_token_path, :scope

      def initialize app, client_id, client_secret, options ={}
        super app, client_id, client_secret, options
        @auth_host = "login.live.com"
        @authorize_path = "/oauth20_authorize.srf"
        @scope = options[:permissions] || "wl.signin, wl.basic, wl.birthday , wl.emails ,wl.contacts_birthday , wl.contacts_photos"
        @auth_token_path = "/oauth20_token.srf"
        @contacts_host = "apis.live.net"
        @contacts_path = "/v5.0/me/contacts"
        @self_path = "/v5.0/me"
      end

      def fetch_contacts_using_access_token access_token, access_token_secret
        fetch_current_user(access_token)
        contacts_response = https_get(@contacts_host, @contacts_path, :access_token => access_token)
        contacts_from_response contacts_response
      end

      def fetch_current_user access_token
        self_response =  https_get(@contacts_host, @self_path, :access_token => access_token)
        user = current_user(self_response, access_token)
        set_current_user user
      end

      private

      def contacts_from_response response_as_json
        response = JSON.parse(response_as_json)
        contacts = []
        response['data'].each do |entry|
          # creating nil fields to keep the fields consistent across other networks
          contact = { :id => nil,
                      :first_name => nil,
                      :last_name => nil,
                      :name => nil,
                      :email => nil,
                      :gender => nil,
                      :birthday => nil,
                      :profile_picture=> nil,
                      :relation => nil,
                      :addresses => nil,
                      :phone_numbers => nil,
                      :emails => nil,
                      :email_hashes => [],
                      :company => nil,
                      :position => nil
                    }
          contact[:id] = entry['user_id'] ? entry['user_id'] : entry['id']
          contact[:email] = entry['emails']['preferred'] if entry['emails']
          if valid_email? entry["name"]
            contact[:email] ||= entry["name"]
            contact[:first_name], contact[:last_name], contact[:name] = email_to_name(contact[:email])
          else
            contact[:first_name] = normalize_name(entry['first_name'])
            contact[:last_name] = normalize_name(entry['last_name'])
            contact[:name] = normalize_name(entry['name'])
          end
          contact[:birthday] = birthday_format(entry['birth_month'], entry['birth_day'], entry['birth_year'])
          contact[:gender] = entry['gender']
          contact[:profile_picture] = image_url(entry['user_id'])
          contact[:email_hashes] = entry['email_hashes']

          contact[:emails] = []
          entry['emails'].each_pair do |label, value|
            next unless value
            contact[:emails] << {:name => label, :email => value}
          end if entry['emails']

          contact[:phone_numbers] = []
          entry['phones'].each_pair do |label, value|
            next unless value
            contact[:phone_numbers] << {:name => label, :number => value}
          end if entry['phones']

          contact[:addresses] = []
          entry['addresses'].each_pair do |label, address|
            new_address = {:name => label}

            new_address[:address_1] = address['street'] if address['street']
            if new_address[:address_1].index("\n")
              parts = new_address[:address_1].split("\n")
              new_address[:address_1] = parts.first
              # this may contain city/state/zip if user jammed it all into one string.... :-(
              new_address[:address_2] = parts[1..-1].join(', ')
            end
            new_address[:address_2] ||= address['street_2'] if address['street_2']
            new_address[:city] = address['city'] if address['city']
            new_address[:region] = address['state'] if address['state'] # like state or province
            new_address[:country] = address['region'] if address['region']
            new_address[:postcode] = address['postal_code'] if address['postal_code']
            contact[:addresses] << new_address
          end if entry['addresses']

          contacts << contact if contact[:name] || contact[:first_name]
        end
        contacts
      end

      def parse_email(emails)
        return nil if emails.nil?
        emails['account']
      end

      def current_user(me, access_token)
        return nil if me.nil?
        me = JSON.parse(me)
        email = parse_email(me['emails'])
        user = {:id => me['id'], :email => email, :name => me['name'], :first_name => me['first_name'],
                :last_name => me['last_name'], :gender => me['gender'], :profile_picture => image_url(me['id']),
                :birthday => birthday_format(me['birth_month'], me['birth_day'], me['birth_year']),
                :access_token => access_token
        }
        user
      end


      def image_url hotmail_id
        return 'https://apis.live.net/v5.0/' + hotmail_id + '/picture' if hotmail_id
      end

      def escape_windows_format value
        value.gsub(/[\r\s]/, '')
      end

      def valid_email? value
        /\A[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]+\z/.match(value)
      end

    end
  end
end
