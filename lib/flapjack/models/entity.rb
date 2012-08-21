#!/usr/bin/env ruby

module Flapjack

  module Data

    class Entity

      def initialize(options = {})
        raise "Redis connection not set" unless @redis = options[:redis]
        raise "Name not set" unless @name = options[:name]
        @logger = options[:logger]
      end

      def check_list
        # This returns too much irrelevant data -- we'll refactor the data model instead
        @redis.keys("#{@name}:*").sort
      end

    end

  end

end
