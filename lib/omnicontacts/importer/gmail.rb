require "omnicontacts/parse_utils"
require "omnicontacts/middleware/oauth2"

module OmniContacts
  module Importer
    class Gmail < Middleware::OAuth2
      include ParseUtils

      attr_reader :auth_host, :authorize_path, :auth_token_path, :scope

      def initialize *args
        super *args
        @auth_host = "accounts.google.com"
        @authorize_path = "/o/oauth2/auth"
        @auth_token_path = "/o/oauth2/token"
        @scope = (args[3] && args[3][:scope]) || "https://www.googleapis.com/auth/contacts.readonly https://www.googleapis.com/auth/contacts.other.readonly https://www.googleapis.com/auth/userinfo#email https://www.googleapis.com/auth/userinfo.profile"
        @contacts_host = "people.googleapis.com"
        @contacts_path = "/v1/people/me/connections"
        @other_contacts_path = "/v1/otherContacts"
        @max_results = (args[3] && args[3][:max_results]) || 100
        @self_host = "www.googleapis.com"
        @profile_path = "/oauth2/v3/userinfo"
      end

      def fetch_contacts_using_access_token access_token, token_type
        fetch_current_user(access_token, token_type)
        contacts_response = JSON.parse(https_get(@contacts_host, @contacts_path, contacts_req_params, contacts_req_headers(access_token, token_type)))
        other_contacts_response = JSON.parse(https_get(@contacts_host, @other_contacts_path, other_contacts_req_params, contacts_req_headers(access_token, token_type)))
        other_contacts_response['otherContacts'].each { |contact| contacts_response['connections'].push(contact) }
        contacts_from_response(contacts_response, access_token)
      end

      def fetch_current_user access_token, token_type
        self_response = https_get(@self_host, @profile_path, contacts_req_params, contacts_req_headers(access_token, token_type))
        user = current_user(self_response, access_token, token_type)
        set_current_user user
      end

      private

      def contacts_req_params
        { 'pageSize': @max_results.to_s, 'personFields': 'names,emailAddresses,birthdays,genders,relations,addresses,phoneNumbers,events,calendarUrls,organizations', 'sources': 'READ_SOURCE_TYPE_CONTACT', 'alt': 'json' }
      end

      def other_contacts_req_params
        { 'pageSize': @max_results.to_s, 'readMask': 'names,emailAddresses,phoneNumbers' }
      end

      def contacts_req_headers token, token_type
        {"GData-Version": "3.0", "Authorization": "#{token_type} #{token}"}
      end

      def contacts_from_response(response, access_token)
        contacts = []
        return contacts if response.nil? || response['connections'].nil?
        response['connections'].each do |entry|
          # creating nil fields to keep the fields consistent across other networks
          contact = { 
            id: nil,
            first_name: nil,
            last_name: nil,
            name: nil,
            emails: nil,
            gender: nil,
            birthday: nil,
            profile_picture: nil,
            relation: nil,
            addresses: nil,
            phone_numbers: nil,
            dates: nil,
            company: nil,
            position: nil
          }

          contact[:id] = entry['resourceName'] if entry['resourceName']
          if entry['names']
            contact[:first_name] = normalize_name(entry['names'].first['givenName']) if entry['names'].first['givenName']
            contact[:last_name] = normalize_name(entry['names'].first['familyName']) if entry['names'].first['familyName']
            contact[:name] = normalize_name(entry['names'].first['unstructuredName']) if entry['names'].first['unstructuredName']
            contact[:name] = full_name(contact[:first_name],contact[:last_name]) if contact[:name].nil?
          end

          contact[:emails] = []
          if entry['emailAddresses']
            entry['emailAddresses'].each do |email|
              contact[:emails] << { name: type_or_other(email['formattedType']), email: email['value'] } 
            end 
            contact[:email] = contact[:emails][0][:email] if contact[:emails][0]
          end

          #format - year-month-date
          contact[:birthday] = entry['birthdays'].first['text'] if entry['birthdays']

          contact[:genders] = entry['genders'].first['formattedValue']  if entry['genders']

          contact[:relation] = entry['relations'].first['type'] if entry['relations']

          contact[:addresses] = []
          if entry['addresses']
            entry['addresses'].each do |address|
              new_address = { name: type_or_other(address['formattedType']) }
              new_address[:address_1] = address['streetAddress'] if address['streetAddress']
              new_address[:address_1] = address['formattedValue'] if new_address[:address_1].nil? && address['formattedValue']
              if new_address[:address_1] && new_address[:address_1].index("\n")
                parts = new_address[:address_1].split("\n")
                new_address[:address_1] = parts.first
                # this may contain city/state/zip if user jammed it all into one string.... :-(
                new_address[:address_2] = parts[1..-1].join(', ')
              end
              new_address[:address_2] = address['extendedAddress'] if new_address[:address_2].nil? && address['extendedAddress'].present?
              new_address[:city] = address['city']if address['city']
              new_address[:region] = address['region'] if address['region'] # like state or province
              new_address[:country] = address['countryCode'] if address['countryCode']
              new_address[:postcode] = address['postalCode'] if address['postalCode']
              contact[:addresses] << new_address
            end
          end

          if entry['organizations']
            contact[:company] = entry['organizations'][0]['name'] if entry['organizations'][0]['name']
            contact[:position] = entry['organizations'][0]['title'] if entry['organizations'][0]['title']
          end

          contact[:phone_numbers] = []
          if entry['phoneNumbers']
            entry['phoneNumbers'].each do |phone_number|
                contact[:phone_numbers] << { name: type_or_other(phone_number['formattedType']), number: phone_number['value'] }
            end
             contact[:phone_numbers].first[:name] = 'main' if set_main?(contact)
          end
          
    
          if entry['events']
            contact[:dates] = []
            entry['events'].each do |event|
                contact[:dates] << {name: type_or_other(event['formattedType']), date: event['date']}
            end
          end
          contacts << contact if contact[:name]
        end
        contacts.uniq! {|c| c[:email] || c[:profile_picture] || c[:name]}
        contacts
      end

      def current_user me, access_token, token_type
        return nil if me.nil?
        me = JSON.parse(me)
        user = {
          id: me['id'], 
          email: me['email'], 
          name: me['name'], 
          first_name: me['given_name'],
          last_name: me['family_name'], 
          gender: me['gender'], 
          birthday: birthday(me['birthday']), 
          profile_picture: me["picture"],
          access_token: access_token, 
          token_type: token_type
        }
        user
      end

      def birthday dob
        return nil if dob.nil?
        birthday = dob.split('-')
        return birthday_format(birthday[2], birthday[3], nil) if birthday.size == 4
        return birthday_format(birthday[1], birthday[2], birthday[0]) if birthday.size == 3
      end

      def contact_id(profile_url)
        id = (profile_url.present?) ? File.basename(profile_url) : nil
        id
      end
    
      private
    
      def type_or_other(type)
        type ?  type : 'other'
      end

      def set_main?(contact)
        return false if contact[:company]
        contact[:phone_numbers].each do |phone_number|
          return false if phone_number[:name] != 'other'
        end
        true
      end
    end
  end
end
