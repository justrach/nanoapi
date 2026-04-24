const dhi = @import("dhi");
const model = @import("dhi-model");

pub const ValidationError = dhi.ValidationError;
pub const ValidationErrors = dhi.ValidationErrors;
pub const ValidationResult = dhi.ValidationResult;

pub const BoundedInt = dhi.BoundedInt;
pub const BoundedString = dhi.BoundedString;
pub const Email = dhi.Email;
pub const Pattern = dhi.Pattern;

pub const Optional = dhi.Optional;
pub const Default = dhi.Default;
pub const OneOf = dhi.OneOf;
pub const Range = dhi.Range;
pub const Transform = dhi.Transform;

pub const StrOpts = model.StrOpts;
pub const IntOpts = model.IntOpts;
pub const FloatOpts = model.FloatOpts;
pub const BoolOpts = model.BoolOpts;
pub const ListOpts = model.ListOpts;
pub const FieldKind = model.FieldKind;
pub const FieldDesc = model.FieldDesc;

pub const Str = model.Str;
pub const Int = model.Int;
pub const Float = model.Float;
pub const Bool = model.Bool;
pub const Model = model.Model;

pub const EmailStr = model.EmailStr;
pub const HttpUrl = model.HttpUrl;
pub const Uuid = model.Uuid;
pub const IPv4 = model.IPv4;
pub const IPv6 = model.IPv6;
pub const IsoDate = model.IsoDate;
pub const IsoDatetime = model.IsoDatetime;
pub const Base64Str = model.Base64Str;
pub const PositiveInt = model.PositiveInt;
pub const NegativeInt = model.NegativeInt;
pub const NonNegativeInt = model.NonNegativeInt;
pub const NonPositiveInt = model.NonPositiveInt;
pub const PositiveFloat = model.PositiveFloat;
pub const NegativeFloat = model.NegativeFloat;
pub const NonNegativeFloat = model.NonNegativeFloat;
pub const NonPositiveFloat = model.NonPositiveFloat;
pub const FiniteFloat = model.FiniteFloat;

pub const parseAndValidate = dhi.parseAndValidate;
pub const batchValidate = dhi.batchValidate;
pub const streamValidate = dhi.streamValidate;
pub const validateStruct = dhi.validateStruct;
pub const deriveValidator = dhi.deriveValidator;
