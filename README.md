# CSVKit for Objective-C

CSVKit is a comma-separated value (CSV) parser for Objective-C.

Copyright &copy; 2011 Booyah, Inc.

Jon Parise <jon@booyah.com>

## Overview

CSVKit provides block-based CSV parsers for Objective-C.  The internal parsing
routines are written in C for speed (and are largely adapted from [Python's
csv module](http://docs.python.org/library/csv.html)).  The parser calls
user-supplied blocks as it incrementally parses the source data.

Because there's no true "standard" for CSV-style data, the parsing rules can
be configured via "dialects".  Dialects define things like the format's field
delimiter and quoting rules.

Currently, values are always either `NSString` or `NSNumber` objects.  Strings
are always treated as UTF8-encoded, and numbers are always interpreted as
doubles.  Numeric values are only recognized if the dialect provides a way to
differentiate numbers from strings (e.g. `CSVQuoteStyleNonNumeric`).

## Installation

Simply include these source files in your project:

* CSVKit.h
* CSVKit.m

The repository also includes a SenTestingKit-compatible unit test:

* CSVKitTests.h
* CSVKitTests.m

## Usage

### Dialects

Dialects dictate the parsing rules and are defined by the `CSVDialect` struct.
You can define your own rules by fillout out a new `CSVDialect` object, or you
can use one of the default dialects provided by CSVKit.

* `CSVExcelDialect` - Excel-generated CSV data
* `CSVExcelTabDialect` - Excel-generated TAB-delimited data

### Field-Based Parsing

The lowest level of parsing occurs at the field level.  Field parsing is
available through the `-parseFieldsFrom*` family of methods on the `CSVParser`
class.

#### Block Callback

    void (^)(id value, NSUInteger index, BOOL *stop)

* `value` - Object representing the parsed field's value
* `index` - 0-based field index; `NSUIntegerMax` at end of line
* `stop`  - Flag that will stop processing if set to `YES`

It's important to handle the `index == NSUIntegerMax` case as that's the only
way to determine when the parser has completed parsing the current line's
values.  Also note that `value` will be `nil` in this case.

### Row-Based Parsing

It's often more convenient to work with complete rows of values.  Row parsing
is available via the `-parseRowsFrom*` methods.

#### Block Callback

    void (^)(NSArray *row, BOOL *stop)

* `row`  - Array of parsed values
* `stop` - Flag that will stop processing if set to `YES`

### Object-Based Parsing

Lastly, it's possible to parse rows of values directly into object properties.
This is a fast and convenient way to build data or model objects directly from
CSV source data.

Because this style of parsing is a bit more specialized, you need to use the
`CSVObjectParser` subclass of `CSVParser`.  This class allows you to specify
both an object class (to use when constructing new per-row object instances)
as well as an array of property names.

    - (id)initWithDialect:(const CSVDialect *)dialect
              objectClass:(Class)objectClass
            propertyNames:(NSArray *)propertyNames;

If `objectClass` is not specified, we default to `NSMutableDictionary`.  If
`propertyNames` is not specified, we use the fields from the first row of data
as the property names.

Object instances are allocated using `-alloc` and initialized using `-init`:

    [[objectClass alloc] init]

Property values are set using `-setValue:forKey:`.  In the future, we may also
support key paths (`-setValue:forKeyPath:`) via an optional flag of some sort,
but key path-based assignment is quite a bit slower at runtime, so it is not
the default behavior.

#### Block Callback

    void (^)(id object, BOOL *stop)

* `object` - Parsed object value
* `stop`   - Flag that will stop processing if set to `YES`

## Future Ideas

* Incremental (stream-based) parsing
* Dialect guessing
* Richer numeric types
* Object caching for frequently-occuring values
* Optimized NSDictionary parsing if there's enough interest
