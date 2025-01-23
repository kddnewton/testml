# frozen_string_literal: true

require "json"

module TestML
  def self.run(filepath)
    json = JSON.parse(File.read(filepath))
    raise "Unsupported TestML version: #{json["testml"]}" if json["testml"] != "0.3.0"

    index = Index.new
    runner = Runner.new(index)

    runner.run(json["code"], json["data"])
    puts "1..#{index}"
  end

  class Index
    def initialize = @value = 0
    def succ! = @value = @value.succ
    def to_s = "#{@value}"
  end

  Mine = Class.new
  NULL = Object.new
  NONE = Object.new
  FALSY = [nil, false, NONE, NULL].freeze

  class Bridge
    def add(left, right)
      left + right
    end

    def cat(*values)
      values.join
    end

    def get_env(key)
      ENV.fetch(key) { NONE }
    end

    def mine
      Mine.new
    end

    def sub(left, right)
      left - right
    end
  end

  class Runner
    def initialize(index)
      @index = index
      @vars = {}
      @bridge = nil
      @label = nil
      @diff = false
      @plan = false
    end

    def run(exprs, env)
      exprs.each { |expr| compile(expr, env) }
    end

    private

    def bridge
      @bridge ||=
        begin
          require ENV.fetch("TESTML_BRIDGE")
          TestML::Bridge.new
        end
    end

    def join_label(parent, child)
      child.gsub(/(\A\+|\+\z|\{\+\})/, parent)
    end

    def assert(positive, got, operator, want, label, env)
      if env.is_a?(Hash)
        label ||= env["Label"]
        label = join_label(label, @label) if @label
      end

      label ||= ""
      label = label.gsub(/\{(\*?.+?)\}/) do
        substitution =
          case (value = $1)
          when "Got" then got
          when "Want" then want
          when /^\*(.+)$/ then env.fetch($1)
          else @vars.fetch(value)
          end

        case substitution
        when String
          substitution.gsub("\n", "␤")
        when Array
          "[#{substitution.map(&:inspect).join(",")}]"
        else
          substitution.inspect
        end
      end

      @index.succ!

      result = got.public_send(operator, want)
      result = !result unless positive

      if result
        puts "ok #{@index} - #{label}"
      else
        puts "not ok #{@index} - #{label}"

        if @diff
          puts "         got: '#{got.inspect}'"
          puts "    expected: '#{want.inspect}'"
        end
      end
    end

    def filters?(filters, env)
      filters.all? do |filter|
        case filter
        in /^\*(.+)$/ then env.key?($1)
        in /^\!\*(.+)$/ then !env.key?($1)
        end
      end
    end

    def compile(expr, env)
      case expr

      # functions
      in ["ArgV"]           then ARGV
      in ["Bool", value]    then !FALSY.include?(compile(value, env))
      in ["Block"]          then env
      in ["Block", label]   then env.find { |env| env["Label"] == label }
      in ["Blocks"]         then env
      in ["Cat", *values]   then values.map { |value| compile(value, env) }.join
      in ["Env"]            then ENV
      in ["Error"]          then StandardError.new
      in ["Error", message] then StandardError.new(message)
      in ["False"]          then false
      in ["None"]           then NONE
      in ["Null"]           then NULL
      in ["Sum", *values]   then values.sum { |value| compile(value, env) }
      in ["Throw", message] then raise StandardError, message
      in ["True"]           then true

      # assignments
      in ["=", "Label", value]
        @label = value
      in ["=", "Diff", value]
        @diff = compile(value, env)
      in ["=", "Plan", value]
        @plan = compile(value, env)
      in ["=", name, value]
        @vars[name] = compile(value, env)
      in ["||=", name, value]
        @vars[name] = compile(value, env) if FALSY.include?(@vars[name])

      # statements
      in ["*", name]
        compile(env.fetch(name), env)
      in ["%<>", filters, ["=>", *] => function]
        env.each do |child_env|
          compile(function, child_env).call([], child_env) if filters?(filters, child_env)
        end
      in ["%<>", filters, expr]
        env.each do |child_env|
          if expr.length == 4
            child_env = { **child_env }
            child_env["Label"] = join_label(child_env["Label"], expr[3])
          end

          compile(expr, child_env) if filters?(filters, child_env)
        end
      in ["<>", filters, ["=>", *] => function]
        compile(function, env).call([], env) if filters?(filters, env)
      in ["<>", filters, expr]
        compile(expr, env) if filters?(filters, env)
      in ["<>", filters, expr, label]
        compile(expr, env.merge("Label" => join_label(env["Label"], label))) if filters?(filters, env)
      in [".", receiver, *calls]
        compile_calls(receiver, calls, env)
      in ["%", inputs, function]
        callable = compile(function, env)
        compile(inputs, env).each { |input| callable.call([[input]], {}) }
      in ["&", expr]
        compile(expr, env).call([], env)
      in ["[]", receiver, index]
        compile(receiver, env).fetch(compile(index, env)) { NONE }
      in [":" | /\Ahash-lookup\z/i, receiver, key]
        compile(receiver, env).fetch(compile(key, env)) { NONE }

      # assertions
      in [("==" | "!==") => operator, left, right, *labels]
        assert(operator == "==", compile(left, env), :==, compile(right, env), labels[0], env)
      in [("=~" | "!=~") => operator, left, right, *labels]
        left = compile(left, env)
        right = compile(right, env)

        Array(right).each do |right|
          Array(left).each do |left|
            assert(operator == "=~", left, :match?, right, labels[0], env)
          end
        end
      in [("~~" | "!~~") => operator, left, right, *labels]
        left = compile(left, env)
        right = compile(right, env)

        Array(right).each do |substring|
          assert(operator == "~~", left, :include?, substring, labels[0], env)
        end

      # types
      in [Array => values]       then values.map { |value| compile(value, env) }
      in [Hash => values]        then values.transform_values { |value| compile(value, env) }
      in String                  then expr
      in Integer                 then expr
      in ["/", pattern]          then Regexp.new(pattern)
      in ["\"", value]           then value.gsub(/\{(.+?)\}/) { @vars.fetch($1) }
      in ["_"]                   then env["inputs"][0][0]
      in ["=>", params, exprs]
        runner = Runner.new(@index)
        exprs = compile_params(params).concat(exprs)
        ->(inputs, env) { runner.run(exprs, env.merge("inputs" => inputs)) }
      in [String => name] if @vars.key?(name)
        @vars.fetch(name)
      in [String => name, *arguments] if @vars.key?(name)
        @vars.fetch(name).call([arguments.map { |argument| compile(argument, env) }], {})
      in [/\A[a-z]/ => name, *arguments]
        bridge.public_send(name.tr("-", "_"), *arguments.map { |argument| compile(argument, env) })
      end
    end

    def compile_params(params)
      params.map.with_index { |param, index| ["=", param, ["[]", ["*", "inputs"], index]] }
    end

    def compile_calls(callee, calls, env)
      calls.inject(-> { compile(callee, env) }) do |callee, call|
        -> {
          case call
          in ["Catch"]
            begin callee.call; rescue => error then error end
          in ["Count"]
            callee.call.count
          in ["Join", delimiter]
            callee.call.join(delimiter)
          in ["Lines"]
            callee.call.split("\n")
          in ["Msg"]
            callee.call.message
          in ["Split", delimiter]
            callee.call.split(delimiter)
          in ["Text"]
            callee.call.map { |line| "#{line}\n" }.join
          in ["Type"]
            compile_type(callee.call)
          in ["=>", params, exprs]
            Runner.new(@index).run(compile_params(params).concat(exprs), { "inputs" => [callee.call] })
          in [String => name, *arguments] if @vars.key?(name)
            @vars.fetch(name).call([[callee.call, *arguments]], {})
          in [/\A[a-z]/ => name, *arguments]
            bridge.public_send(name.tr("-", "_"), callee.call, *arguments.map { |argument| compile(argument, env) })
          else
            begin callee.call; rescue => error then raise end
            raise StandardError, "Unknown call: #{call.inspect}"
          end
        }
      end.call
    end

    def compile_type(object)
      case object
      in Array then "list"
      in Hash then "hash"
      in Integer then "num"
      in Mine then "native"
      in NONE then "none"
      in NULL then "null"
      in Proc then "func"
      in Regexp then "regex"
      in StandardError then "error"
      in String then "str"
      in TrueClass | FalseClass then "bool"
      end
    end
  end
end
