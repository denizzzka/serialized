module text.xml.Decode;

import boilerplate.util : udaIndex;
static import dxml.util;
import meta.attributesOrNothing;
import meta.never;
import meta.SafeUnqual;
import std.format : format;
import sumtype;
import text.xml.Validation : enforceName, normalize, require, requireChild;
import text.xml.Tree;
public import text.xml.Xml;

/**
 * Throws: XmlException if the message is not well-formed or doesn't match the type
 */
public T decode(T, alias customDecode = never)(string message)
{
    import text.xml.Parser : parse;

    static assert(__traits(isSame, customDecode, never), "XML does not yet support a decode function");

    XmlNode rootNode = parse(message);

    return decodeXml!T(rootNode);
}

/**
 * Throws: XmlException if the XML element doesn't match the type
 */
public T decodeXml(T)(XmlNode node)
{
    import std.traits : fullyQualifiedName;

    static assert(
        udaIndex!(Xml.Element, __traits(getAttributes, T)) != -1,
        fullyQualifiedName!T ~
        ": type passed to text.xml.decode must have an Xml.Element attribute indicating its element name.");

    enum name = __traits(getAttributes, T)[udaIndex!(Xml.Element, __traits(getAttributes, T))].name;

    node.enforceName(name);

    return decodeUnchecked!T(node);
}

/**
 * Throws: XmlException if the XML element doesn't match the type
 * Returns: T, or the type returned from a decoder function defined on T.
 */
public auto decodeUnchecked(T, attributes...)(XmlNode node)
{
    import boilerplate.util : formatNamed, optionallyRemoveTrailingUnderline, udaIndex;
    import std.algorithm : map;
    import std.meta : AliasSeq, anySatisfy, ApplyLeft;
    import std.range : array, ElementType;
    import std.string : strip;
    import std.traits : fullyQualifiedName, isIterable, Unqual;
    import std.typecons : Nullable, Tuple;

    static if (isNodeLeafType!(T, attributes))
    {
        return decodeNodeLeaf!(T, attributes)(node);
    }
    else
    {
        static assert(
            __traits(hasMember, T, "ConstructorInfo"),
            fullyQualifiedName!T ~ " does not have a boilerplate constructor!");

        auto builder = T.Builder();

        alias Info = Tuple!(string, "builderField", string, "constructorField");

        static foreach (string constructorField; T.ConstructorInfo.fields)
        {{
            enum builderField = optionallyRemoveTrailingUnderline!constructorField;

            mixin(formatNamed!q{
                alias Type = Unqual!(T.ConstructorInfo.FieldInfo.%(constructorField).Type);
                alias attributes = AliasSeq!(T.ConstructorInfo.FieldInfo.%(constructorField).attributes);

                static if (is(Type : Nullable!Arg, Arg))
                {
                    alias DecodeType = Arg;
                    enum isNullable = true;
                }
                else
                {
                    alias DecodeType = SafeUnqual!Type;
                    enum isNullable = false;
                }

                static if (is(Type : SumType!T, T...))
                {
                    builder.%(builderField) = decodeSumType!T(node);
                }
                else static if (udaIndex!(Xml.Attribute, attributes) != -1)
                {
                    enum name = attributes[udaIndex!(Xml.Attribute, attributes)].name;

                    static if (isNullable || T.ConstructorInfo.FieldInfo.%(constructorField).useDefault)
                    {
                        if (name in node.attributes)
                        {
                            builder.%(builderField) = decodeAttributeLeaf!(DecodeType, name, attributes)(node);
                        }
                    }
                    else
                    {
                        builder.%(builderField) = decodeAttributeLeaf!(DecodeType, name, attributes)(node);
                    }
                }
                else static if (udaIndex!(Xml.Element, attributes) != -1)
                {
                    enum name = attributes[udaIndex!(Xml.Element, attributes)].name;

                    enum canDecodeNode = isNodeLeafType!(DecodeType, attributes)
                        || __traits(compiles, .decodeUnchecked!(DecodeType, attributes)(XmlNode.init));

                    static if (canDecodeNode)
                    {
                        static if (isNullable || T.ConstructorInfo.FieldInfo.%(constructorField).useDefault)
                        {
                            static assert(
                                T.ConstructorInfo.FieldInfo.%(constructorField).useDefault,
                                format!"%s.%(constructorField) is Nullable, but missing @(This.Default)!"
                                    (fullyQualifiedName!T));

                            auto child = node.findChild(name);

                            if (!child.isNull)
                            {
                                builder.%(builderField) = decodeUnchecked!(DecodeType, attributes)(child.get);
                            }
                        }
                        else
                        {
                            auto child = node.requireChild(name);

                            builder.%(builderField) = .decodeUnchecked!(DecodeType, attributes)(child);
                        }
                    }
                    else static if (is(DecodeType: U[], U))
                    {
                        alias decodeChild = delegate U(XmlNode child)
                        {
                            return .decodeUnchecked!(U, attributes)(child);
                        };

                        auto children = node.findChildren(name).map!decodeChild.array;

                        builder.%(builderField) = children;
                    }
                    else
                    {
                        pragma(msg, "While decoding field '" ~ name ~ "' of type " ~ DecodeType.stringof ~ ":");

                        // reproduce the error we swallowed earlier
                        auto _ = .decodeUnchecked!(DecodeType, attributes)(XmlNode.init);
                    }
                }
                else static if (udaIndex!(Xml.Text, attributes) != -1)
                {
                    builder.%(builderField) = dxml.util.decodeXML(node.text);
                }
                else
                {
                    enum sameField(string lhs, string rhs)
                        = optionallyRemoveTrailingUnderline!lhs == optionallyRemoveTrailingUnderline!rhs;
                    enum memberIsAliasedToThis = anySatisfy!(
                        ApplyLeft!(sameField, constructorField),
                        __traits(getAliasThis, T));

                    static if (memberIsAliasedToThis)
                    {
                        // decode inline
                        builder.%(builderField) = .decodeUnchecked!(DecodeType, attributes)(node);
                    }
                    else
                    {
                        static assert(
                            T.ConstructorInfo.FieldInfo.%(constructorField).useDefault,
                            "Field " ~ fullyQualifiedName!T ~ ".%(constructorField) is required but has no Xml tag");
                    }
                }
            }.values(Info(builderField, constructorField)));
        }}

        return builder.builderValue();
    }
}

/**
 * Throws: XmlException if the XML element doesn't have a child matching exactly one of the subtypes,
 * or if the child doesn't match the subtype.
 */
private SumType!Types decodeSumType(Types...)(XmlNode node)
{
    import std.algorithm : find, map, moveEmplace, sum;
    import std.array : array, front;
    import std.exception : enforce;
    import std.meta : AliasSeq, staticMap;
    import std.typecons : apply, Nullable, nullable;
    import text.xml.XmlException : XmlException;

    Nullable!(SumType!Types)[Types.length] decodedValues;

    static foreach (i, Type; Types)
    {{
        static if (is(Type: U[], U))
        {
            alias attributes = AliasSeq!(__traits(getAttributes, U));
            enum isArray = true;
        }
        else
        {
            alias attributes = AliasSeq!(__traits(getAttributes, Type));
            enum isArray = false;
        }

        static assert(
            udaIndex!(Xml.Element, attributes) != -1,
            fullyQualifiedName!Type ~
            ": SumType component type must have an Xml.Element attribute indicating its element name.");

        enum name = attributes[udaIndex!(Xml.Element, attributes)].name;

        static if (isArray)
        {
            auto children = node.findChildren(name);

            if (!children.empty)
            {
                decodedValues[i] = SumType!Types(children.map!(a => a.decodeUnchecked!U).array);
            }
        }
        else
        {
            auto child = node.findChild(name);

            decodedValues[i] = child.apply!(a => SumType!Types(a.decodeUnchecked!Type));
        }
    }}

    const matchedValues = decodedValues[].map!(a => a.isNull ? 0 : 1).sum;

    enforce!XmlException(matchedValues != 0,
        format!`Element "%s": no child element of %(%s, %)`(node.tag, [staticMap!(typeName, Types)]));
    enforce!XmlException(matchedValues == 1,
        format!`Element "%s": contained more than one of %(%s, %)`(node.tag, [staticMap!(typeName, Types)]));
    return decodedValues[].find!(a => !a.isNull).front.get;
}

private enum typeName(T) = T.stringof;

private auto decodeAttributeLeaf(T, string name, attributes...)(XmlNode node)
{
    alias typeAttributes = attributesOrNothing!T;

    static if (udaIndex!(Xml.Decode, attributes) != -1)
    {
        alias decodeFunction = attributes[udaIndex!(Xml.Decode, attributes)].DecodeFunction;

        return decodeFunction(dxml.util.decodeXML(node.attributes[name]));
    }
    else static if (udaIndex!(Xml.Decode, typeAttributes) != -1)
    {
        alias decodeFunction = typeAttributes[udaIndex!(Xml.Decode, typeAttributes)].DecodeFunction;

        return decodeFunction(dxml.util.decodeXML(node.attributes[name]));
    }
    else
    {
        return node.require!T(name);
    }
}

// must match decodeNodeLeaf
enum isNodeLeafType(T, attributes...) =
    udaIndex!(Xml.Decode, attributes) != -1
    || udaIndex!(Xml.Decode, attributesOrNothing!T) != -1
    || __traits(compiles, XmlNode.init.require!(SafeUnqual!T)());

private auto decodeNodeLeaf(T, attributes...)(XmlNode node)
{
    alias typeAttributes = attributesOrNothing!T;

    static if (udaIndex!(Xml.Decode, attributes) != -1 || udaIndex!(Xml.Decode, typeAttributes) != -1)
    {
        static if (udaIndex!(Xml.Decode, attributes) != -1)
        {
            alias decodeFunction = attributes[udaIndex!(Xml.Decode, attributes)].DecodeFunction;
        }
        else
        {
            alias decodeFunction = typeAttributes[udaIndex!(Xml.Decode, typeAttributes)].DecodeFunction;
        }

        static if (__traits(isTemplate, decodeFunction))
        {
            return decodeFunction!T(node);
        }
        else
        {
            return decodeFunction(node);
        }
    }
    else static if (is(T == string))
    {
        return dxml.util.decodeXML(node.text).normalize;
    }
    else
    {
        return node.require!(SafeUnqual!T)();
    }
}