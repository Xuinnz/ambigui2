//The single raylib C import. Every UI file must use this one: separate
//@cImport calls of the same header produce distinct, incompatible types.
pub const c = @cImport(@cInclude("raylib.h"));
