#
# TextParser.rb - TaskJuggler
#
# Copyright (c) 2006, 2007 by Chris Schlaeger <cs@kde.org>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of version 2 of the GNU General Public License as
# published by the Free Software Foundation.
#
# $Id$
#

require 'TextParserPattern'
require 'TextParserRule'
require 'TextScanner'
require 'TextParserStackElement'

# The TextParser implements a regular LALR parser. But it uses a recursive
# rule traversor instead of the more commonly found state machine generated by
# yacc-like tools. Since stack depths is not really an issue with a Ruby
# implementation this approach has one big advantage. The parser can be
# modified during parsing. This allows support for languages that can extend
# themself. The TaskJuggler syntax is such an beast. Traditional yacc
# generated parsers would fail with such a syntax.
#
# This class is just a base class. A complete parser would derive from this
# class and implement the rule set and the functions _nextToken()_ and
# _returnToken()_.
#
# To describe the syntax the functions TextParser#newRule,
# TextParser#newPattern, TextParser#optional and
# TextParser#repeatable can be used. When the rule set is changed during
# parsing, TextParser#updateParserTables must be called to make the changes
# effective.
#
# To start parsing the input the function TextParser#parse needs to be called
# with the name of the start rule.
class TextParser

  def initialize
    @rules = { }
    @cr = nil
    @@debug = 0
  end

  # Add a new rule to the rule set. _name_ must be a unique identifier. The
  # function also sets the class variable @cr to the new rule. Subsequent
  # calls to TextParser#newPattern, TextParser#optional or
  # TextParser@repeatable will then implicitely operate on the most recently
  # added rule.
  def newRule(name)
    raise "Fatal Error: Rule #{name} already exists" if @rules.has_key?(name)

    @rules[name] = @cr = TextParserRule.new(name)
  end

  # Add a new pattern to the most recently added rule. _tokens_ is an array of
  # strings that specify the syntax elements of the pattern. Each token must
  # start with an character that identifies the type of the token. The
  # following types are supported.
  #
  # * ! a reference to another rule
  # * $ a variable token as delivered by the scanner
  # * _ a literal token.
  #
  # _func_ is a Proc object that is called whenever the parser has completed
  # the processing of this rule.
  def newPattern(tokens, func = nil)
    @cr.addPattern(TextParserPattern.new(tokens, func))
  end

  # Identify the patterns of the most recently added rule as optional syntax
  # elements.
  def optional
    @cr.setOptional
  end

  # Identify the patterns of the most recently added rule as repeatable syntax
  # elements.
  def repeatable
    @cr.setRepeatable
  end

  # This function needs to be called whenever new rules or patterns have been
  # added and before the next call to TextParser#parse.
  def updateParserTables
    @rules.each_value { |rule| rule.transitions = {} }
    @rules.each_value { |rule| getTransitions(rule) }
  end

  # To parse the input this function needs to be called with the name of the
  # rule to start with.
  def parse(ruleName)
    @stack = []
    updateParserTables
    result = parseRule(@rules[ruleName])

    if nextToken != [ false, false ]
      error("Synatx error")
    end

    result
  end

  # Call this function to report any errors related to the parsed input.
  def error(text)
    # Very preliminary implementation.
    $stderr.puts @scanner.line
    raise text
  end

private

  # getTransitions recursively determines all possible target tokens
  # that the _rule_ matches. A target token can either be a fixed
  # token (prefixed with _) or a variable token (prefixed with $). The
  # list of found target tokens is stored in the _transitions_ list of
  # the rule. For each rule pattern we store the transitions for this
  # pattern in a token -> rule hash.
  def getTransitions(rule)
    transitions = []
    # If we have processed this rule before we can just return a copy
    # of the transitions of this rule. This avoids endless recursions.
    return rule.transitions.clone unless rule.transitions.empty?

    rule.patterns.each do |pat|
      next if pat.empty?
      token = pat[0].slice(1, pat[0].length - 1)
      if pat[0][0] == ?!
        result = { }
        unless @rules.has_key?(token)
          raise "Fatal Error: Unknown reference to #{token} in pattern " +
                "#{pat} + of rule #{rule.name}"
        end
        res = getTransitions(@rules[token])
        # Combine the hashes for each pattern into a single hash
        res.each do |pat|
          pat.each { |tok, r| result[tok] = r }
        end
      elsif pat[0][0] == ?_ || pat[0][0] == ?$
        result = { pat[0] => rule }
      else
        raise "Fatel Error: Illegal token type specifier used for token" +
	      ": #{token}"
      end
      # Make sure that we only have one possible transition for each
      # target.
      result.each do |key, value|
        transitions.each do |trans|
          if trans.has_key?(key)
	    raise "Fatal Error: Rule #{rule.name} has ambigeous transitions " +
	          "for target #{key}"
	  end
	end
      end
      transitions << result
    end
    # Store the list of found transitions with the rule.
    rule.transitions = transitions.clone
  end

  # This function processes the input starting with the syntax description of
  # _rule_. It recursively calls this function whenever the syntax description
  # contains the reference to another rule.
  def parseRule(rule)
    puts "Parsing with rule #{rule.name}" if @@debug >= 10
    result = rule.repeatable ? [] : nil
    # Rules can be marked 'repeatable'. This flag will be set to true after
    # the first iternation has been completed.
    repeatMode = false
    loop do
      # At the beginning of a rule we need a token from the input to determine
      # which pattern of the rule needs to be processed.
      begin
        token = nextToken
        puts "  Token: #{token[0]}/#{token[1]}" if @@debug >= 20
      rescue TjException
        error("Error: " + $!)
      end

      # The scanner cannot differentiate between keywords and identifiers. So
      # whenever an identifier is returned we have to see if we have a
      # matching keyword first. If none is found, then look for normal
      # identifiers.
      if token[0] == "ID"
        if (patIdx = rule.matchingPatternIndex("_" + token[1])).nil?
          patIdx = rule.matchingPatternIndex("$ID")
        end
      elsif token[0] == "LITERAL"
        patIdx = rule.matchingPatternIndex("_" + token[1])
      elsif token[0] == false
        patIdx = nil
      else
        patIdx = rule.matchingPatternIndex("$" + token[0])
      end

      # If no matching pattern is found for the token we have to check if the
      # rule is optional or we are in repeat mode. If this is the case, return
      # the token back to the scanner. Otherwise we have found a token we
      # cannot handle at this point.
      if patIdx.nil?
        unless rule.optional || repeatMode
          error("Unexpected token '#{token[1]}' of type '#{token[0]}'")
        end
        returnToken(token)
        puts "Finished parsing with rule #{rule.name} (*)" if @@debug >= 10
        return result
      end

      pattern = rule.pattern(patIdx)
      @stack << TextParserStackElement.new(rule, pattern.function)

      pattern.each do |element|
        # Separate the type and token text for pattern element.
        elType = element[0]
        elToken = element.slice(1, element.length - 1)
        if elType == ?!
          # The element is a reference to another rule. Return the token if we
          # still have one and continue with the referenced rule.
          unless token.nil?
            returnToken(token)
            token = nil
          end
          @stack.last.store(parseRule(@rules[elToken]))
        else
          # In case the element is a keyword or variable we have to get a new
          # token if we don't have one anymore.
          if token.nil?
            begin
              if (token = nextToken) == [ false, false ]
                error("Unexpected end of file")
              end
            rescue TjException
              error("Error: " + $!)
            end
          end

          if elType == ?_
            # If the element requires a keyword the token must match this
            # keyword.
            error("#{elToken} expected") if token[1] != elToken
            @stack.last.store(elToken)
          else
            # The token must match the expected variable type.
            error("#{elToken} expected") if token[0] != elToken
            # If the element is a variable store the value of the token.
            @stack.last.store(token[1])
          end
          # The token has been consumed. Reset the variable.
          token = nil
        end
      end

      # Once the complete pattern has been processed we call the processing
      # function for this pattern to operate on the value array. Then pop the
      # entry for this rule from the stack.
      @val = @stack.last.val
      res = nil
      begin
        res = @stack.last.function.call unless @stack.last.function.nil?
      rescue TjException
        error("Error: " + $!)
      end
      @stack.pop

      # If the rule is not repeatable we can store the result and break the
      # outer loop to exit the function.
      unless rule.repeatable
        result = res
        break
      end

      # Otherwise we append the result to the result array and turn repeat
      # mode on.
      result << res
      repeatMode = true
    end

    puts "Finished parsing with rule #{rule.name}" if @@debug >= 10
    return result
  end

end
