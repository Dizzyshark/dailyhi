require "active_record"
require "openssl"
require "mail"
require "resolv"
require "flickr_fu"
require "tzinfo"
require "open-uri"
require "rss"
require "erb"

Mail.defaults do
  delivery_method :sendmail
end

env = ENV["RACK_ENV"] || "development"
HOSTNAME = env == "development" ? "localhost:3000" : "dailyhi.com"

config = YAML.load_file("#{File.dirname(__FILE__)}/config/database.yml")
ActiveRecord::Base.establish_connection config[env]
conn = ActiveRecord::Base.connection
unless conn.table_exists?("subscriptions")
  conn.create_table "subscriptions" do |t|
    t.string  :code,     null: false, limit: 64
    t.string  :email,    null: false
    t.boolean :verified, null: false, default: false
    t.integer :timezone, limit: 1, default: -8
    t.timestamp
  end
  conn.add_index :subscriptions, :email
  conn.add_index :subscriptions, :code
  conn.add_index :subscriptions, :verified
  conn.add_index :subscriptions, :timezone
end


class Subscription < ActiveRecord::Base
  attr_accessible :email, :verified, :timezone
  attr_readonly :email, :code
  validates_presence_of :email
  validates_uniqueness_of :email, :code

  named_scope :verified, lambda { { conditions: { verified: true } } }

  before_validation do |record|
    record.email = Mail::Address.new(record.email).to_s.downcase
  end
  validate do |record|
    addr = Mail::Address.new(record.email) rescue nil
    if addr && addr.domain.present?
      mx = Resolv::DNS.open { |dns| dns.getresources(addr.domain, Resolv::DNS::Resource::IN::MX) }
      record.errors.add :email, :invalid if mx.empty?
    else
      record.errors.add :email, :invalid
    end
  end

  before_create do |record|
    record.verified = false
    record.code = OpenSSL::Random::random_bytes(16).unpack("H*").first
  end

  after_create do |record|
    Mail.deliver do
      from "The Daily Hi <hi@dailyhi.com>"
      to record.email
      subject "Please verify your email address"
      url = "http://#{HOSTNAME}/verify/#{record.code}"
      text_part do
        body <<-BODY
Before you can receive emails, we need to verify your email address.

Daily bliss, after you click this link:
  #{url}

        BODY
      end
    end
  end

  # Returns this subscription's "now" for immediate delivery.  For example:
  #   Subscription.deliver Subscription.find(1).my_now 
  def my_now
    utc = Time.now.utc
    now = Time.utc(utc.year, utc.month, utc.day, 6 - timezone)
  end

  class << self
    def deliver(utc = Time.now.utc)
      hour = utc.hour - 6 # 6 AM
      timezone = hour < 12 ? -hour : 24 - hour
      tz = TZInfo::Timezone.all_data_zones.find { |tz| tz.current_period.utc_offset.to_i == timezone * 60 * 60 }
      return unless tz
      time = tz.utc_to_local(utc)
      photo = find_photo(time)
      fact = fun_fact(time)

      subject = "Good morning, today is #{time.strftime("%A")}!"
      find_each conditions: { verified: true, timezone: timezone } do |subscription|
        Mail.deliver do
          from "The Daily Hi <hi@dailyhi.com>"
          to subscription.email
          subject subject
          html_part do
            content_type "text/html"
            body email(subscription, time, photo, fact)
          end
        end
      end
    end

    def find_photo(time)
      flickr = Flickr.new("#{File.dirname(__FILE__)}/config/flickr.yml")
      photos = flickr.photos.search(privacy_filter: 1, safe: 1, content_type: 1, license: "4,5,6",
                                    min_upload_date: (Date.today - 1).to_time.to_i, sort: "interestingness-desc")
      photo = photos.find { |photo|
        large = photo.photo_size(:large)
        large && (800..1400).include?(large.width.to_i) && (600..1400).include?(large.height.to_i) }
    end

    def fun_fact(time)
      if time.wday == 0
        # Chunk Norris fact
        week = time.strftime("%W").to_i || rand(52)
        File.read("chuck.txt").split("\n")[week]
      else
        facts = File.read("facts.txt").split("\n")
        facts[rand(facts.length)]
      end
    rescue
=begin
      open("http://www.factropolis.com/rss.xml") do |response|
        result = RSS::Parser.parse(response, false)
        item = result.items.first
        return [item.title, item.link] if item
      end
=end
    end

    def email(subscription, time, photo, fact)
      medium = photo.photo_size(:large) if photo
      erb = ERB.new(File.read(File.dirname(__FILE__) + "/views/email.erb"))
      erb.result binding
    end
  end
end


Subscription.deliver if $0 == __FILE__
