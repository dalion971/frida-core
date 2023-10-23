[CCode (gir_namespace = "FridaXPC", gir_version = "1.0")]
namespace Frida.XPC {
	public class PairingBrowser : Object {
		public signal void service_discovered (string name, string host, uint16 port, Bytes txt_record);

		public void * _backend;

		construct {
			_backend = _create_backend (this);
		}

		~PairingBrowser () {
			_destroy_backend (_backend);
		}

		public void _on_match (string name, string host, uint16 port, Bytes txt_record) {
			service_discovered (name, host, port, txt_record);
		}

		public extern static void * _create_backend (PairingBrowser browser);
		public extern static void _destroy_backend (void * backend);
	}

	public class ServiceConnection : Object, AsyncInitable {
		public string host {
			get;
			construct;
		}

		public uint16 port {
			get;
			construct;
		}

		private SocketConnection connection;
		private InputStream input;
		private OutputStream output;
		private Cancellable io_cancellable = new Cancellable ();

		public NGHttp2.Session session;

		private Stream root_stream;
		private Stream reply_stream;

		private bool is_processing_messages;

		private ByteArray? send_queue;
		private Source? send_source;

		public ServiceConnection (string host, uint16 port) {
			Object (host: host, port: port);
		}

		construct {
			NGHttp2.SessionCallbacks callbacks;
			NGHttp2.SessionCallbacks.make (out callbacks);

			callbacks.set_send_callback ((session, data, flags, user_data) => {
				ServiceConnection * self = user_data;
				return self->on_send (data, flags);
			});
			callbacks.set_on_begin_frame_callback ((session, hd, user_data) => {
				ServiceConnection * self = user_data;
				return self->on_begin_frame (hd);
			});
			callbacks.set_on_data_chunk_recv_callback ((session, flags, stream_id, data, user_data) => {
				ServiceConnection * self = user_data;
				return self->on_data_chunk_recv (flags, stream_id, data);
			});
			callbacks.set_on_frame_recv_callback ((session, frame, user_data) => {
				ServiceConnection * self = user_data;
				return self->on_frame_recv (frame);
			});
			callbacks.set_on_stream_close_callback ((session, stream_id, error_code, user_data) => {
				ServiceConnection * self = user_data;
				return self->on_stream_close (stream_id, error_code);
			});
			callbacks.set_error_callback ((session, code, msg, user_data) => {
				ServiceConnection * self = user_data;
				return self->on_error (code, msg);
			});

			NGHttp2.Option option;
			NGHttp2.Option.make (out option);
			option.set_no_auto_window_update (true);
			option.set_peer_max_concurrent_streams (100);
			option.set_no_http_messaging (true);
			// option.set_no_http_semantics (true);
			option.set_no_closed_streams (true);

			NGHttp2.ClientSession.make (out session, callbacks, this, option);
		}

		private async bool init_async (int io_priority, Cancellable? cancellable) throws Error, IOError {
			try {
				var connectable = NetworkAddress.parse (host, port);

				var client = new SocketClient ();
				printerr ("Connecting to %s:%u...\n", host, port);
				connection = yield client.connect_async (connectable, cancellable);

				printerr ("Connected to %s:%u\n", host, port);

				Tcp.enable_nodelay (connection.socket);

				input = connection.get_input_stream ();
				output = connection.get_output_stream ();

				is_processing_messages = true;

				process_incoming_messages.begin ();

				session.submit_settings (NGHttp2.Flag.NONE, {
					{ MAX_CONCURRENT_STREAMS, 100 },
					{ INITIAL_WINDOW_SIZE, 1048576 },
				});

				session.set_local_window_size (NGHttp2.Flag.NONE, 0, 1048576);

				root_stream = make_stream ();

				Bytes header_request = new RequestBuilder (HEADER)
					.begin_dictionary ()
					.end_dictionary ()
					.build ();
				yield submit_data (root_stream.id, header_request);

				Bytes ping_request = new RequestBuilder (PING)
					.build ();
				yield submit_data (root_stream.id, ping_request);

				reply_stream = make_stream ();

				Bytes open_reply_channel_request = new RequestBuilder (HEADER, HEADER_OPENS_REPLY_CHANNEL)
					.build ();
				yield submit_data (reply_stream.id, open_reply_channel_request);
			} catch (GLib.Error e) {
				throw new Error.NOT_SUPPORTED ("%s", e.message);
			}

			return true;
		}

		private void maybe_send_pending () {
			while (session.want_write ()) {
				bool would_block = send_source != null && send_queue == null;
				if (would_block)
					break;

				session.send ();
			}
		}

		private async void submit_data (int32 stream_id, Bytes bytes) throws Error, IOError {
			bool waiting = false;
			var op = new SubmitOperation (bytes, () => {
				if (waiting)
					submit_data.callback ();
				return Source.REMOVE;
			});

			var data_prd = NGHttp2.DataProvider ();
			data_prd.source.ptr = op;
			data_prd.read_callback = on_data_provider_read;
			int result = session.submit_data (NGHttp2.DataFlag.NO_END_STREAM, stream_id, data_prd);
			if (result < 0)
				throw new Error.PROTOCOL ("%s", NGHttp2.strerror (result));

			maybe_send_pending ();

			while (op.cursor != bytes.get_size ()) {
				waiting = true;
				yield;
				waiting = false;
			}
		}

		private static ssize_t on_data_provider_read (NGHttp2.Session session, int32 stream_id, uint8[] buf, ref uint32 data_flags,
				NGHttp2.DataSource source, void * user_data) {
			var op = (SubmitOperation) source.ptr;

			unowned uint8[] data = op.bytes.get_data ();

			uint remaining = data.length - op.cursor;
			if (remaining == 0) {
				data_flags |= NGHttp2.DataFlag.EOF;
				op.callback ();
				return 0;
			}

			uint n = uint.min (remaining, buf.length);
			Memory.copy (buf, (uint8 *) data + op.cursor, n);

			op.cursor += n;

			return n;
		}

		private class SubmitOperation {
			public Bytes bytes;
			public SourceFunc callback;

			public uint cursor = 0;

			public SubmitOperation (Bytes bytes, owned SourceFunc callback) {
				this.bytes = bytes;
				this.callback = (owned) callback;
			}
		}

		private async void process_incoming_messages () {
			while (is_processing_messages) {
				try {
					var buffer = new uint8[4096];

					ssize_t n = yield input.read_async (buffer, Priority.DEFAULT, io_cancellable);
					if (n == 0) {
						printerr ("EOF!\n");
						is_processing_messages = false;
						continue;
					}

					ssize_t result = session.mem_recv (buffer[:n]);
					if (result < 0)
						throw new Error.PROTOCOL ("%s", NGHttp2.strerror (result));

					session.consume_connection (n);
				} catch (GLib.Error e) {
					printerr ("Oops: %s\n", e.message);
					is_processing_messages = false;
				}
			}
		}

		private ssize_t on_send (uint8[] data, int flags) {
			if (send_source == null) {
				send_queue = new ByteArray.sized (1024);

				var source = new IdleSource ();
				source.set_callback (() => {
					do_send.begin ();
					return Source.REMOVE;
				});
				source.attach (MainContext.get_thread_default ());
				send_source = source;
			}

			if (send_queue == null)
				return NGHttp2.ErrorCode.WOULDBLOCK;

			send_queue.append (data);
			return data.length;
		}

		private async void do_send () {
			uint8[] buffer = send_queue.steal ();
			send_queue = null;

			try {
				size_t bytes_written;
				yield output.write_all_async (buffer, Priority.DEFAULT, io_cancellable, out bytes_written);
			} catch (GLib.Error e) {
				printerr ("write_all_async() failed: %s\n", e.message);
			}

			send_source = null;

			maybe_send_pending ();
		}

		private int on_begin_frame (NGHttp2.FrameHd hd) {
			printerr ("\non_begin_frame() length=%zu stream_id=%d type=%u flags=0x%x reserved=%u\n", hd.length, hd.stream_id, hd.type, hd.flags, hd.reserved);
			if (hd.type != DATA)
				return 0;

			Stream? stream = find_stream_by_id (hd.stream_id);
			if (stream == null)
				return -1;

			return stream.on_begin_frame (hd);
		}

		private int on_data_chunk_recv (uint8 flags, int32 stream_id, uint8[] data) {
			printerr ("on_data_chunk_recv() flags=0x%x stream_id=%d\n", flags, stream_id);

			Stream? stream = find_stream_by_id (stream_id);
			if (stream == null)
				return -1;

			return stream.on_data_chunk_recv (data);
		}

		private int on_frame_recv (NGHttp2.Frame frame) {
			printerr ("on_frame_recv() length=%zu stream_id=%d type=%u flags=0x%x reserved=%u\n", frame.hd.length, frame.hd.stream_id, frame.hd.type, frame.hd.flags, frame.hd.reserved);

			if (frame.hd.type != DATA)
				return 0;

			Stream? stream = find_stream_by_id (frame.hd.stream_id);
			if (stream == null)
				return -1;

			if (stream.incoming_message == null)
				return -1;

			printerr ("Ready to parse:\n");
			hexdump (stream.incoming_message.data);

			return 0;
		}

		private int on_stream_close (int32 stream_id, uint32 error_code) {
			printerr ("on_stream_close() stream_id=%d error_code=%u\n", stream_id, error_code);
			return 0;
		}

		private int on_error (NGHttp2.ErrorCode code, char[] msg) {
			string m = ((string) msg).substring (0, msg.length);
			printerr ("on_error() code=%d msg=\"%s\"\n", code, m);
			return 0;
		}

		private Stream make_stream () {
			int stream_id = session.submit_headers (NGHttp2.Flag.NONE, -1, null, {}, null);
			maybe_send_pending ();

			return new Stream (stream_id);
		}

		private Stream? find_stream_by_id (int32 id) {
			if (root_stream.id == id)
				return root_stream;
			if (reply_stream.id == id)
				return reply_stream;
			return null;
		}

		private class Stream {
			public int32 id;

			public ByteArray? incoming_message;

			private const size_t MAX_MESSAGE_SIZE = 10 * 1024 * 1024; // TODO: Revisit

			public Stream (int32 id) {
				this.id = id;
			}

			public int on_begin_frame (NGHttp2.FrameHd hd) {
				if (hd.length > MAX_MESSAGE_SIZE)
					return -1;
				incoming_message = new ByteArray.sized ((uint) hd.length);
				return 0;
			}

			public int on_data_chunk_recv (uint8[] data) {
				if (incoming_message == null)
					return -1;
				incoming_message.append (data);
				return 0;
			}
		}
	}

	public class RequestBuilder : ObjectBuilder {
		private const uint32 MAGIC = 0x29b00b92;
		private const uint8 PROTOCOL_VERSION = 1;

		private MessageType message_type;
		private MessageFlags message_flags;
		private uint64 message_id;

		public RequestBuilder (MessageType message_type, MessageFlags message_flags = NONE, uint64 message_id = 0) {
			this.message_type = message_type;
			this.message_flags = message_flags;
			this.message_id = message_id;
		}

		public override Bytes build () {
			Bytes body = base.build ();

			return new BufferBuilder (8, LITTLE_ENDIAN)
				.append_uint32 (MAGIC)
				.append_uint8 (PROTOCOL_VERSION)
				.append_uint8 (message_type)
				.append_uint16 (message_flags)
				.append_uint64 (body.length)
				.append_uint64 (message_id)
				.append_bytes (body)
				.build ();
		}
	}

	public enum MessageType {
		HEADER,
		MSG,
		PING,
	}

	[Flags]
	public enum MessageFlags {
		NONE				= 0,
		WANTS_REPLY			= (1 << 0),
		IS_REPLY			= (1 << 1),
		HEADER_OPENS_STREAM_TX		= (1 << 4),
		HEADER_OPENS_STREAM_RX		= (1 << 5),
		HEADER_OPENS_REPLY_CHANNEL	= (1 << 6),
	}

	public class ObjectBuilder {
		private BufferBuilder builder = new BufferBuilder (8, LITTLE_ENDIAN);
		private Gee.Deque<Scope> scopes = new Gee.ArrayQueue<Scope> ();

		private const uint32 MAGIC = 0x42133742;
		private const uint32 VERSION = 5;

		public ObjectBuilder () {
			builder
				.append_uint32 (MAGIC)
				.append_uint32 (VERSION);
		}

		public unowned ObjectBuilder begin_dictionary () {
			builder.append_uint32 (ObjectType.DICTIONARY);

			size_t length_offset = builder.offset;
			builder.append_uint32 (0);

			size_t num_entries_offset = builder.offset;
			builder.append_uint32 (0);

			push_scope (new DictionaryScope (length_offset, num_entries_offset));

			return this;
		}

		public unowned ObjectBuilder end_dictionary () {
			DictionaryScope scope = pop_scope ();

			uint32 length = (uint32) (builder.offset - scope.num_entries_offset);
			builder.write_uint32 (scope.length_offset, length);

			builder.write_uint32 (scope.num_entries_offset, scope.num_entries);

			return this;
		}

		public unowned ObjectBuilder add_uint64 (uint64 val) {
			builder
				.append_uint32 (ObjectType.UINT64)
				.append_uint64 (val);
			return this;
		}

		public unowned ObjectBuilder add_string (string val) {
			var scope = peek_scope ();

			if (scope.kind != DICTIONARY)
				builder.append_uint32 (ObjectType.STRING);

			builder
				.append_string (val)
				.align (4);

			if (scope.kind == DICTIONARY)
				((DictionaryScope) scope).num_entries++;

			return this;
		}

		public virtual Bytes build () {
			return builder.build ();
		}

		private void push_scope (Scope scope) {
			scopes.offer_head (scope);
		}

		private Scope peek_scope () {
			return scopes.peek_head ();
		}

		private T pop_scope<T> () {
			return (T) scopes.poll_head ();
		}

		private class Scope {
			public Kind kind;

			public enum Kind {
				DICTIONARY,
			}

			protected Scope (Kind kind) {
				this.kind = kind;
			}
		}

		private class DictionaryScope : Scope {
			public size_t length_offset;
			public size_t num_entries_offset;

			public uint num_entries = 0;

			public DictionaryScope (size_t length_offset, size_t num_entries_offset) {
				base (DICTIONARY);
				this.length_offset = length_offset;
				this.num_entries_offset = num_entries_offset;
			}
		}
	}

	private enum ObjectType {
		UINT64     = 0x00004000,
		STRING     = 0x00009000,
		DICTIONARY = 0x0000f000,
	}

	// https://gist.github.com/phako/96b36b5070beaf7eee27
	private void hexdump (uint8[] data) {
		var builder = new StringBuilder.sized (16);
		var i = 0;

		foreach (var c in data) {
			if (i % 16 == 0)
				printerr ("%08x | ", i);

			printerr ("%02x ", c);

			if (((char) c).isprint ())
				builder.append_c ((char) c);
			else
				builder.append (".");

			i++;
			if (i % 16 == 0) {
				printerr ("| %s\n", builder.str);
				builder.erase ();
			}
		}

		if (i % 16 != 0)
			printerr ("%s| %s\n", string.nfill ((16 - (i % 16)) * 3, ' '), builder.str);
	}
}

