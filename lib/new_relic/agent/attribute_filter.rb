# encoding: utf-8
# This file is distributed under New Relic's license terms.
# See https://github.com/newrelic/rpm/blob/master/LICENSE for complete details.

# This class applies filtering rules as specified in the Agent Attributes
# cross-agent spec.
#
# Instances of it are constructed by deriving a set of rules from the agent
# configuration. Instances are immutable once they are constructed - if the
# config changes, a new instance should be constructed and swapped in to
# replace the existing one.
#
# The #apply method is the main external interface of this class. It takes an
# attribute name and a set of default destinations (represented as a bitfield)
# and returns a set of actual destinations after applying the filtering rules
# specified in the config.
#
# Each set of destinations is represented as a bitfield, where the bit positions
# specified in the DST_* constants are used to indicate whether an attribute
# should be sent to the corresponding destination.
#
# The choice of a bitfield here rather than an Array was made to avoid the need
# for any transient object allocations during the application of rules. Since
# rule application will happen once per attribute per transaction, this is a hot
# code path.
#
# The algorithm for applying filtering rules is as follows:
#
# 1. Start with a bitfield representing the set of default destinations passed
#    in to #apply.
# 2. Mask this bitfield against the set of destinations that have attribute
#    enabled at all.
# 3. Traverse the list of rules in order (more on the ordering later), applying
#    each matching rule, but taking care to not let rules override the enabled
#    status of each destination. Each matching rule may mutate the bitfield.
# 4. Return the resulting bitfield after all rules have been applied.
#
# Each rule consists of a name, a flag indicating whether it ends with a
# wildcard, a bitfield representing the set of destinations that it applies to,
# and a flag specifying whether it is an include or exclude rule.
#
# During construction, rules are sorted according to the following criteria:
#
# 1. First, the names are compared lexicographically. This has the impact of
#    forcing shorter (more general) rules towards the top of the list and longer
#    (more specific) rules towards the bottom. This is important, because the
#    Agent Attributes spec stipulates that the most specific rule for a given
#    destination should take precedence. Since rules are applied top-to-bottom,
#    this sorting guarantees that the most specific rule will be applied last.
# 2. If the names are identical, we next examine the wildcard flag. Rules ending
#    with a wildcard are considered more general (and thus 'less than') rules
#    not ending with a wildcard.
# 3. If the names and wildcard flags are identical, we next examine whether the
#    rules being compared are include or exclude rules. Exclude rules have
#    precedence by the spec, so they are considered 'greater than' include
#    rules.
#
# This approach to rule evaluation was taken from the PHP agent's
# implementation.
#

module NewRelic
  module Agent
    class AttributeFilter
      DST_NONE = 0x0

      DST_TRANSACTION_EVENTS = 1 << 0
      DST_TRANSACTION_TRACER = 1 << 1
      DST_ERROR_COLLECTOR    = 1 << 2
      DST_BROWSER_MONITORING = 1 << 3

      DST_ALL = 0xF

      attr_reader :rules

      def initialize(config)
        @enabled_destinations = DST_NONE

        @enabled_destinations |= DST_TRANSACTION_TRACER if config[:'transaction_tracer.attributes.enabled']
        @enabled_destinations |= DST_TRANSACTION_EVENTS if config[:'transaction_events.attributes.enabled']
        @enabled_destinations |= DST_ERROR_COLLECTOR    if config[:'error_collector.attributes.enabled']
        @enabled_destinations |= DST_BROWSER_MONITORING if config[:'browser_monitoring.attributes.enabled']

        @enabled_destinations = DST_NONE unless config[:'attributes.enabled']

        @rules = []

        build_rule(config[:'attributes.exclude'], DST_ALL, false)
        build_rule(config[:'transaction_tracer.attributes.exclude'], DST_TRANSACTION_TRACER, false)
        build_rule(config[:'transaction_events.attributes.exclude'], DST_TRANSACTION_EVENTS, false)
        build_rule(config[:'error_collector.attributes.exclude'],    DST_ERROR_COLLECTOR,    false)
        build_rule(config[:'browser_monitoring.attributes.exclude'], DST_BROWSER_MONITORING, false)

        build_rule(['request.parameters.*'],   include_destinations_for_capture_params(:capture_params, config), true)
        build_rule(['jobs.resque.arguments'],  include_destinations_for_capture_params(:'resque.capture_params', config), true)
        build_rule(['jobs.sidekiq.arguments'], include_destinations_for_capture_params(:'sidekiq.capture_params', config), true)

        build_rule(config[:'attributes.include'], DST_ALL, true)
        build_rule(config[:'transaction_tracer.attributes.include'], DST_TRANSACTION_TRACER, true)
        build_rule(config[:'transaction_events.attributes.include'], DST_TRANSACTION_EVENTS, true)
        build_rule(config[:'error_collector.attributes.include'],    DST_ERROR_COLLECTOR,    true)
        build_rule(config[:'browser_monitoring.attributes.include'], DST_BROWSER_MONITORING, true)

        @rules.sort!

        cache_parameter_capture_flags
      end

      def include_destinations_for_capture_params(key, config)
        if config[key]
          DST_TRANSACTION_TRACER | DST_ERROR_COLLECTOR
        else
          DST_NONE
        end
      end

      def build_rule(attribute_names, destinations, is_include)
        attribute_names.each do |attribute_name|
          rule = AttributeFilterRule.new(attribute_name, destinations, is_include)
          @rules << rule unless rule.empty?
        end
      end

      def apply(attribute_name, default_destinations)
        return DST_NONE if @enabled_destinations == DST_NONE

        destinations   = default_destinations
        attribute_name = attribute_name.to_s

        @rules.each do |rule|
          if rule.match?(attribute_name)
            if rule.is_include
              destinations |= rule.destinations
            else
              destinations &= rule.destinations
            end
          end
        end

        destinations & @enabled_destinations
      end

      def allows?(allowed_destinations, requested_destination)
        allowed_destinations & requested_destination == requested_destination
      end

      # In the default case, we don't capture HTTP request parameters, or job
      # arguments for Sidekiq or Resque.
      #
      # Just traversing the parameters hash or argument list in order to
      # generate flattened key names and apply filtering to each parameter/arg
      # can be expensive, so we fast-path the default case here by statically
      # determining that there's no way these attributes will be allowed through
      # and exposing some flags that clients can use in order to predicate their
      # work processing the parameters/arguments.
      def cache_parameter_capture_flags
        @might_allow_request_parameters = might_allow_attribute_with_prefix?('request.parameters')
        @might_allow_sidekiq_args       = might_allow_attribute_with_prefix?('job.sidekiq.arguments')
        @might_allow_resque_args        = might_allow_attribute_with_prefix?('job.resque.arguments')
      end

      def might_allow_request_parameters?
        @might_allow_request_parameters
      end

      def might_allow_sidekiq_args?
        @might_allow_sidekiq_args
      end

      def might_allow_resque_args?
        @might_allow_resque_args
      end

      def might_allow_attribute_with_prefix?(prefix)
        @rules.any? do |rule|
          if rule.is_include
            if rule.wildcard
              if rule.attribute_name.size > prefix.size
                rule.attribute_name.start_with?(prefix)
              else
                prefix.start_with?(rule.attribute_name)
              end
            else
              rule.attribute_name.start_with?(prefix)
            end
          end
        end
      end
    end

    class AttributeFilterRule
      attr_reader :attribute_name, :destinations, :is_include, :wildcard

      def initialize(attribute_name, destinations, is_include)
        @attribute_name = attribute_name.sub(/\*$/, "")
        @wildcard       = attribute_name.end_with?("*")
        @is_include     = is_include
        @destinations   = is_include ? destinations : ~destinations
      end

      # Rules are sorted from least specific to most specific
      #
      # All else being the same, wildcards are considered less specific
      # All else being the same, include rules are less specific than excludes
      def <=>(other)
        name_cmp = @attribute_name <=> other.attribute_name
        return name_cmp unless name_cmp == 0

        if wildcard != other.wildcard
          return wildcard ? -1 : 1
        end

        if is_include != other.is_include
          return is_include ? -1 : 1
        end

        return 0
      end

      def match?(name)
        if wildcard
          name.start_with?(@attribute_name)
        else
          @attribute_name == name
        end
      end

      def empty?
        if is_include
          @destinations == AttributeFilter::DST_NONE
        else
          @destinations == AttributeFilter::DST_ALL
        end
      end
    end
  end
end
