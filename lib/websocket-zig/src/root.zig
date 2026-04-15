//! Vendored karlseguin/websocket.zig — client only, patched for Zig 0.16.
//! Original: https://github.com/karlseguin/websocket.zig (MIT license)

pub const Client = @import("client/client.zig").Client;
pub const Message = @import("proto.zig").Message;
pub const MessageType = Message.Type;
pub const OpCode = @import("proto.zig").OpCode;
