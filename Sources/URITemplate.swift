//
//  URITemplate.swift
//  URITemplate
//
//  Created by Kyle Fuller on 25/11/2014.
//  Copyright (c) 2014 Kyle Fuller. All rights reserved.
//

import Foundation

#if !swift(>=3.0)
  
  extension SequenceType where Generator.Element == String {
    @warn_unused_result
    func joined(separator separator: String) -> String {
      return self.joinWithSeparator(separator)
    }
  }
  
  extension SequenceType {
    @warn_unused_result
    public func enumerated() -> EnumerateSequence<Self> {
      return enumerate()
    }
  }
  
  extension CollectionType where Index : RandomAccessIndexType {
    @warn_unused_result
    public func reversed() -> ReverseRandomAccessCollection<Self> {
      return reverse()
    }
  }
  
  extension BidirectionalIndexType {
    @warn_unused_result
    public func advanced(by n: Self.Distance, limit: Self) -> Self{
    return advancedBy(n, limit: limit)
    }
  }
  
#endif

// MARK: URITemplate

/// A data structure to represent an RFC6570 URI template.
public struct URITemplate : CustomStringConvertible, Equatable, Hashable, StringLiteralConvertible, ExtendedGraphemeClusterLiteralConvertible, UnicodeScalarLiteralConvertible {
  /// The underlying URI template
  public let template:String
  
  var regex:NSRegularExpression {
    let expression: NSRegularExpression?
    do {
      expression = try NSRegularExpression(pattern: "\\{([^\\}]+)\\}", options: NSRegularExpressionOptions(rawValue: 0))
    } catch let error as NSError {
      fatalError("Invalid Regex \(error)")
    }
    return expression!
  }
  
  var operators:[Operator] {
    return [
      StringExpansion(),
      ReservedExpansion(),
      FragmentExpansion(),
      LabelExpansion(),
      PathSegmentExpansion(),
      PathStyleParameterExpansion(),
      FormStyleQueryExpansion(),
      FormStyleQueryContinuation(),
    ]
  }
  
  /// Initialize a URITemplate with the given template
  public init(template:String) {
    self.template = template
  }
  
  public typealias ExtendedGraphemeClusterLiteralType = StringLiteralType
  public init(extendedGraphemeClusterLiteral value: ExtendedGraphemeClusterLiteralType) {
    template = value
  }
  
  public typealias UnicodeScalarLiteralType = StringLiteralType
  public init(unicodeScalarLiteral value: UnicodeScalarLiteralType) {
    template = value
  }
  
  public init(stringLiteral value: StringLiteralType) {
    template = value
  }
  
  /// Returns a description of the URITemplate
  public var description:String {
    return template
  }
  
  public var hashValue:Int {
    return template.hashValue
  }
  
  /// Returns the set of keywords in the URI Template
  public var variables:[String] {
    let expressions = regex.matches(template).map { expression in
      // Removes the { and } from the expression
      expression.substring(with: expression.startIndex.successor()..<expression.endIndex.predecessor())
    }
    
    return expressions.map { expression -> [String] in
      var expression = expression
      
      for op in self.operators {
        if let op = op.op {
          if expression.hasPrefix(op) {
            expression = expression.substring(from: expression.startIndex.successor())
            break
          }
        }
      }
      
      return expression.componentsSeparated(by: ",").map { component in
        if component.hasSuffix("*") {
          return component.substring(to: component.endIndex.predecessor())
        } else {
          return component
        }
      }
      }.reduce([], combine: +)
  }
  
  /// Expand template as a URI Template using the given variables
  public func expand(variables:[String:AnyObject]) -> String {
    return regex.substitute(template) { string in
      var expression = string[string.startIndex.successor()..<string.endIndex.predecessor()]
      let firstCharacter = expression.substring(to: expression.startIndex.successor())
      
      var op = self.operators.filter {
        if let op = $0.op {
          return op == firstCharacter
        }
        
        return false
        }.first
      
      if (op != nil) {
        expression = expression.substring(to: expression.startIndex.successor())
      } else {
        op = self.operators.first
      }
      
      let rawExpansions = expression.componentsSeparated(by: ",").map { vari -> String? in
        var variable = vari
        var prefix:Int?
        
        if let range = variable.range(of: ":") {
          prefix = Int(variable.substring(from: range.endIndex))
          variable = variable.substring(to: range.startIndex)
        }
        
        let explode = variable.hasSuffix("*")
        
        if explode {
          variable = variable.substring(to: variable.endIndex.predecessor())
        }
        
        if let value:AnyObject = variables[variable] {
          return op!.expand(variable, value: value, explode: explode, prefix:prefix)
        }
        
        return op!.expand(variable, value:nil, explode:false, prefix:prefix)
      }
      
      let expansions = rawExpansions.reduce([], combine: { (accumulator, expansion) -> [String] in
        if let expansion = expansion {
          return accumulator + [expansion]
        }
        
        return accumulator
      })
      
      if expansions.count > 0 {
        return op!.prefix + expansions.joined(separator: op!.joiner)
      }
      
      return ""
    }
  }
  
  func regexForVariable(variable:String, op:Operator?) -> String {
    if op != nil {
      return "(.*)"
    } else {
      return "([A-z0-9%_\\-]+)"
    }
  }
  
  func regexForExpression(expression:String) -> String {
    var expression = expression
    
    let op = operators.filter {
      $0.op != nil && expression.hasPrefix($0.op!)
      }.first
    
    if op != nil {
      expression = expression.substring(with: expression.startIndex.successor()..<expression.endIndex)
    }
    
    let regexes = expression.componentsSeparated(by: ",").map { variable -> String in
      return self.regexForVariable(variable, op: op)
    }
    return regexes.joined(separator: (op ?? StringExpansion()).joiner)
  }
  
  var extractionRegex:NSRegularExpression? {
    let regex = try! NSRegularExpression(pattern: "(\\{([^\\}]+)\\})|[^(.*)]", options: NSRegularExpressionOptions(rawValue: 0))
    
    let pattern = regex.substitute(self.template) { expression in
      if expression.hasPrefix("{") && expression.hasSuffix("}") {
        let startIndex = expression.startIndex.successor()
        let endIndex = expression.endIndex.predecessor()
        return self.regexForExpression(expression.substring(with: startIndex..<endIndex))
      } else {
        return NSRegularExpression.escapedPattern(for: expression)
      }
    }
    
    do {
      return try NSRegularExpression(pattern: "^\(pattern)$", options: NSRegularExpressionOptions(rawValue: 0))
    } catch _ {
      return nil
    }
  }
  
  /// Extract the variables used in a given URL
  public func extract(url:String) -> [String:String]? {
    if let expression = extractionRegex {
      let input = NSString(string: url)
      let range = NSRange(location: 0, length: input.length)
      let results = expression.matches(in: url, options: NSMatchingOptions(rawValue: 0), range: range)
      
      if let result = results.first {
        var extractedVariables = Dictionary<String, String>()
        
        for (index, variable) in variables.enumerated() {
          let range = result.range(at: index + 1)
          let value = input.substring(with: range).removingPercentEncoding
          extractedVariables[variable] = value
        }
        
        return extractedVariables
      }
    }
    
    return nil
  }
}

/// Determine if two URITemplate's are equivalent
public func ==(lhs:URITemplate, rhs:URITemplate) -> Bool {
  return lhs.template == rhs.template
}

// MARK: Extensions

extension NSRegularExpression {
  func substitute(string:String, block:((String) -> (String))) -> String {
    let oldString = NSString(string: string)
    let range = NSRange(location: 0, length: oldString.length)
    var newString = NSString(string: string)
    
    let matches = self.matches(in: string, options: NSMatchingOptions(rawValue: 0), range: range)
    for match in Array(matches.reversed()) {
      let expression = oldString.substring(with: match.range)
      let replacement = block(expression)
      newString = NSString(string: newString.replacingCharacters(in: match.range, with: replacement))
    }
    
    return String(newString)
  }
  
  func matches(string:String) -> [String] {
    let input = NSString(string: string)
    let range = NSRange(location: 0, length: input.length)
    let results = matches(in: string, options: NSMatchingOptions(rawValue: 0), range: range)
    
    return results.map { result -> String in
      return input.substring(with: result.range)
    }
  }
}

extension String {
  func percentEncoded() -> String {
    let allowedCharacters = NSCharacterSet(charactersIn: ":/?&=;+!@#$()',* ").inverted
    return addingPercentEncoding(withAllowedCharacters: allowedCharacters)!
  }
}

// MARK: Operators

protocol Operator {
  /// Operator
  var op:String? { get }
  
  /// Prefix for the expanded string
  var prefix:String { get }
  
  /// Character to use to join expanded components
  var joiner:String { get }
  
  func expand(variable:String, value:AnyObject?, explode:Bool, prefix:Int?) -> String?
}

class BaseOperator {
  var joiner:String { return "," }
  
  func expand(variable:String, value:AnyObject?, explode:Bool, prefix:Int?) -> String? {
    if let value:AnyObject = value {
      if let values = value as? [String:AnyObject] {
        return expand(variable:variable, value: values, explode: explode)
      } else if let values = value as? [AnyObject] {
        return expand(variable:variable, value: values, explode: explode)
      } else if let _ = value as? NSNull {
        return expand(variable:variable)
      } else {
        return expand(variable:variable, value:"\(value)", prefix:prefix)
      }
    }
    
    return expand(variable:variable)
  }
  
  // Point to overide to expand a value (i.e, perform encoding)
  func expand(value  value:String) -> String {
    return value
  }
  
  // Point to overide to expanding a string
  func expand(variable  variable:String, value:String, prefix:Int?) -> String {
    if let prefix = prefix {
      if value.characters.count > prefix {
        let index = value.startIndex.advanced(by: prefix, limit: value.endIndex)
        return expand(value: value.substring(to: index))
      }
    }
    
    return expand(value: value)
  }
  
  // Point to overide to expanding an array
  func expand(variable  variable:String, value:[AnyObject], explode:Bool) -> String? {
    let joiner = explode ? self.joiner : ","
    return value.map { self.expand(value: "\($0)") }.joined(separator: joiner)
  }
  
  // Point to overide to expanding a dictionary
  func expand(variable  variable:String, value:[String:AnyObject], explode:Bool) -> String? {
    let joiner = explode ? self.joiner : ","
    let keyValueJoiner = explode ? "=" : ","
    let elements = value.map({ (key, value) -> String in
      let expandedKey = self.expand(value: key)
      let expandedValue = self.expand(value: "\(value)")
      return "\(expandedKey)\(keyValueJoiner)\(expandedValue)"
    })
    
    return elements.joined(separator: joiner)
  }
  
  // Point to overide when value not found
  func expand(variable  variable:String) -> String? {
    return nil
  }
}

/// RFC6570 (3.2.2) Simple String Expansion: {var}
class StringExpansion : BaseOperator, Operator {
  var op:String? { return nil }
  var prefix:String { return "" }
  override var joiner:String { return "," }
  
  override func expand(value  value:String) -> String {
    return value.percentEncoded()
  }
}

/// RFC6570 (3.2.3) Reserved Expansion: {+var}
class ReservedExpansion : BaseOperator, Operator {
  var op:String? { return "+" }
  var prefix:String { return "" }
  override var joiner:String { return "," }
  
  override func expand(value  value:String) -> String {
    return value.addingPercentEncoding(withAllowedCharacters: NSCharacterSet.urlQueryAllowed())!
  }
}

/// RFC6570 (3.2.4) Fragment Expansion {#var}
class FragmentExpansion : BaseOperator, Operator {
  var op:String? { return "#" }
  var prefix:String { return "#" }
  override var joiner:String { return "," }
  
  override func expand(value  value:String) -> String {
    return value.addingPercentEncoding(withAllowedCharacters: NSCharacterSet.urlFragmentAllowed())!
  }
}

/// RFC6570 (3.2.5) Label Expansion with Dot-Prefix: {.var}
class LabelExpansion : BaseOperator, Operator {
  var op:String? { return "." }
  var prefix:String { return "." }
  override var joiner:String { return "." }
  
  override func expand(value  value:String) -> String {
    return value.percentEncoded()
  }
  
  override func expand(variable  variable:String, value:[AnyObject], explode:Bool) -> String? {
    if value.count > 0 {
      return super.expand(variable: variable, value: value, explode: explode)
    }
    
    return nil
  }
}

/// RFC6570 (3.2.6) Path Segment Expansion: {/var}
class PathSegmentExpansion : BaseOperator, Operator {
  var op:String? { return "/" }
  var prefix:String { return "/" }
  override var joiner:String { return "/" }
  
  override func expand(value value:String) -> String {
    return value.addingPercentEncoding(withAllowedCharacters: NSCharacterSet.urlPathAllowed())!
  }
  
  override func expand(variable  variable:String, value:[AnyObject], explode:Bool) -> String? {
    if value.count > 0 {
      return super.expand(variable: variable, value: value, explode: explode)
    }
    
    return nil
  }
}

/// RFC6570 (3.2.7) Path-Style Parameter Expansion: {;var}
class PathStyleParameterExpansion : BaseOperator, Operator {
  var op:String? { return ";" }
  var prefix:String { return ";" }
  override var joiner:String { return ";" }
  
  override func expand(value  value:String) -> String {
    return value.percentEncoded()
  }
  
  override func expand(variable  variable:String, value:String, prefix:Int?) -> String {
    if value.characters.count > 0 {
      let expandedValue = super.expand(variable: variable, value: value, prefix: prefix)
      return "\(variable)=\(expandedValue)"
    }
    
    return variable
  }
  
  override func expand(variable  variable:String, value:[AnyObject], explode:Bool) -> String? {
    let joiner = explode ? self.joiner : ","
    let expandedValue = value.map {
      let expandedValue = self.expand(value: "\($0)")
      
      if explode {
        return "\(variable)=\(expandedValue)"
      }
      
      return expandedValue
      }.joined(separator: joiner)
    
    if !explode {
      return "\(variable)=\(expandedValue)"
    }
    
    return expandedValue
  }
  
  override func expand(variable  variable:String, value:[String:AnyObject], explode:Bool) -> String? {
    let expandedValue = super.expand(variable: variable, value: value, explode: explode)
    
    if let expandedValue = expandedValue {
      if (!explode) {
        return "\(variable)=\(expandedValue)"
      }
    }
    
    return expandedValue
  }
}

/// RFC6570 (3.2.8) Form-Style Query Expansion: {?var}
class FormStyleQueryExpansion : BaseOperator, Operator {
  var op:String? { return "?" }
  var prefix:String { return "?" }
  override var joiner:String { return "&" }
  
  override func expand(value  value:String) -> String {
    return value.percentEncoded()
  }
  
  override func expand(variable  variable:String, value:String, prefix:Int?) -> String {
    let expandedValue = super.expand(variable: variable, value: value, prefix: prefix)
    return "\(variable)=\(expandedValue)"
  }
  
  override func expand(variable  variable:String, value:[AnyObject], explode:Bool) -> String? {
    if value.count > 0 {
      let joiner = explode ? self.joiner : ","
      let expandedValue = value.map {
        let expandedValue = self.expand(value: "\($0)")
        
        if explode {
          return "\(variable)=\(expandedValue)"
        }
        
        return expandedValue
        }.joined(separator: joiner)
      
      if !explode {
        return "\(variable)=\(expandedValue)"
      }
      
      return expandedValue
    }
    
    return nil
  }
  
  override func expand(variable  variable:String, value:[String:AnyObject], explode:Bool) -> String? {
    if value.count > 0 {
      let expandedVariable = self.expand(value: variable)
      let expandedValue = super.expand(variable: variable, value: value, explode: explode)
      
      if let expandedValue = expandedValue {
        if (!explode) {
          return "\(expandedVariable)=\(expandedValue)"
        }
      }
      
      return expandedValue
    }
    
    return nil
  }
}

/// RFC6570 (3.2.9) Form-Style Query Continuation: {&var}
class FormStyleQueryContinuation : BaseOperator, Operator {
  var op:String? { return "&" }
  var prefix:String { return "&" }
  override var joiner:String { return "&" }
  
  override func expand(value  value:String) -> String {
    return value.percentEncoded()
  }
  
  override func expand(variable  variable:String, value:String, prefix:Int?) -> String {
    let expandedValue = super.expand(variable: variable, value: value, prefix: prefix)
    return "\(variable)=\(expandedValue)"
  }
  
  override func expand(variable  variable:String, value:[AnyObject], explode:Bool) -> String? {
    let joiner = explode ? self.joiner : ","
    let expandedValue = value.map {
      let expandedValue = self.expand(value: "\($0)")
      
      if explode {
        return "\(variable)=\(expandedValue)"
      }
      
      return expandedValue
      }.joined(separator: joiner)
    
    if !explode {
      return "\(variable)=\(expandedValue)"
    }
    
    return expandedValue
  }
  
  override func expand(variable  variable:String, value:[String:AnyObject], explode:Bool) -> String? {
    let expandedValue = super.expand(variable: variable, value: value, explode: explode)
    
    if let expandedValue = expandedValue {
      if (!explode) {
        return "\(variable)=\(expandedValue)"
      }
    }
    
    return expandedValue
  }
}
