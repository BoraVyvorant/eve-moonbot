require 'date'
require 'esi-client-bvv'
require 'oauth2'
require 'set'
require 'slack-notifier'
require 'yaml'

#
# Load the configuration file named on the command line,
# or 'config.yaml' by default.
#
config = YAML.load_file(ARGV[0] || 'config.yaml')

#
# Get an OAuth2 access token for ESI.
#

client = OAuth2::Client.new(config[:client_id], config[:client_secret],
                            site: 'https://login.eveonline.com')

# Wrap the refresh token.
refresh_token = OAuth2::AccessToken.new(client, '',
                                        refresh_token: config[:refresh_token])

# Refresh to get the access token.
access_token = refresh_token.refresh!

#
# Get the owner information for the refresh token.
#
response = access_token.get('/oauth/verify')
character_info = response.parsed
character_id = character_info['CharacterID']

#
# Configure ESI with our access token.
#
ESI.configure do |conf|
  conf.access_token = access_token.token
end

universe_api = ESI::UniverseApi.new
corporation_api = ESI::CorporationApi.new
character_api = ESI::CharacterApi.new
industry_api = ESI::IndustryApi.new

#
# From the public information about the character, locate the corporation ID.
#
character = character_api.get_characters_character_id(character_id)
corporation_id = character.corporation_id

#
# Get the list of corporation structures.
#
structures = corporation_api.get_corporations_corporation_id_structures(corporation_id)

#
# Acquire the list of mining extractions.
#
extractions = industry_api.get_corporation_corporation_id_mining_extractions(corporation_id)

#
# If configured, remove any extractions which finish too far in the future
# to be interesting.
#
if (days = config[:days])
  extractions.delete_if { |ex| (ex.chunk_arrival_time - DateTime.now) > days }
end

#
# If a list of system names has been configured, remove any extractions
# taking place outside those systems.
#
if config[:systems]
  # Make a set of IDs for the named systems
  systems = universe_api.post_universe_ids(config[:systems]).systems
  system_ids = Set.new(systems.map(&:id))
  # Delete extractions in systems not included in that set
  extractions.delete_if do |ex|
    structure = structures.detect { |s| s.structure_id == ex.structure_id }
    !system_ids.include?(structure.system_id)
  end
end

# Sort by arrival time
extractions.sort_by!(&:chunk_arrival_time)

# Map each extraction to a Slack attachment
attachments = extractions.map do |ex|
  structure_p = universe_api.get_universe_structures_structure_id(ex.structure_id)
  structure = structures.detect { |s| s.structure_id == ex.structure_id }
  moon = universe_api.get_universe_moons_moon_id(ex.moon_id)
  # Remove the system name from the start of the structure name
  structure_name = structure_p.name.sub(/^.* - /, '')
  abs_time = ex.chunk_arrival_time.to_time.to_i
  local_time = "<!date^#{abs_time}^{date_long} at {time}|x>"
  eve_time = ex.chunk_arrival_time.strftime('%A, %Y-%m-%d %H:%M:%S')
  stuff = config[:minerals][moon.name] || 'Unknown.'
  {
    title: "#{structure_name} (#{moon.name})",
    color: 'good',
    text: stuff,
    fallback: "#{ex.chunk_arrival_time.strftime('%A at %H:%M')} " \
              "at #{structure_name}",
    fields: [
      { title: 'Your local time', value: local_time, short: true },
      { title: 'EVE time', value: eve_time, short: true }
    ],
    thumb_url: "https://imageserver.eveonline.com/Render/#{structure.type_id}_128.png"
  }
end

#
# Configure Slack.
#

slack_config = config[:slack]
notifier = Slack::Notifier.new slack_config[:webhook_url] do
  defaults slack_config[:defaults]
end

#
# Send a Slack ping if we have anything to say.
#
unless attachments.empty?
  notifier.ping 'Upcoming moon mining opportunities:',
                attachments: attachments
end
