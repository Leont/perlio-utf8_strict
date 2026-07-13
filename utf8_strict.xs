#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#include "perliol.h"
#include "ppport.h"

#define UTF8_VALID_STREAM_PROBE_WINDOW_SIZE 1024
#include "utf8_dfa32.h"
#include "utf8_valid_stream.h"

#define UTF8_MAX_BYTES 4

typedef enum {
	ALLOW_SURROGATES = 1,
	ALLOW_NONCHARACTERS = 2,
	ALLOW_NONSHORTEST = 4
} utf8_flags;

#if defined(PERL_STATIC_NO_RET) && defined(__attribute__noreturn__)
PERL_STATIC_NO_RET void report_illformed(pTHX_ const U8 *cur, STRLEN len, bool eof) __attribute__noreturn__;
#elif defined(__attribute__noreturn__)
static void report_illformed(pTHX_ const U8 *cur, STRLEN len, bool eof) __attribute__noreturn__;
#endif

static void report_illformed(pTHX_ const U8 *cur, STRLEN len, bool eof) {
	static const char *hex = "0123456789ABCDEF";
	const char *fmt;
	char seq[UTF8_MAX_BYTES * 3];
	char *d = seq;

	if (eof)
		fmt = "Can't decode ill-formed UTF-8 octet sequence <%s> at end of file";
	else
		fmt = "Can't decode ill-formed UTF-8 octet sequence <%s>";

	while (len-- > 0) {
		const U8 c = *cur++;
		*d++ = hex[c >> 4];
		*d++ = hex[c & 15];
		if (len)
			*d++ = ' ';
	}
	*d = 0;
	Perl_croak(aTHX_ fmt, seq);
}

static STRLEN validate_streaming(pTHX_ utf8_valid_stream_t *stream, const U8 *source, STRLEN source_length, STRLEN carried, PerlIO *handle) {
	const U8 *chunk = source + carried;
	const bool eof = PerlIO_eof(handle);
	utf8_valid_stream_result_t result;
	STRLEN valid_bytes = 0;

	result = utf8_valid_stream_check(stream, (const char *)chunk, source_length - carried, eof);
	if (result.consumed > 0)
		valid_bytes = carried + result.consumed;

	switch (result.status) {
		case UTF8_VALID_STREAM_OK:
		case UTF8_VALID_STREAM_PARTIAL:
			break;

		case UTF8_VALID_STREAM_ILLFORMED:
		case UTF8_VALID_STREAM_TRUNCATED:
		{
			const U8 *bad = chunk + result.consumed - result.carried;
			const STRLEN bad_len = result.carried + result.advance;
			PerlIOBase(handle)->flags |= PERLIO_F_ERROR;
			report_illformed(aTHX_ bad, bad_len, eof);
			break;
		}
	}

	return valid_bytes;
}

typedef struct {
	PerlIOBuf buf;
	utf8_valid_stream_t stream;
	size_t pending_offset;
	size_t pending_length;
} PerlIOUnicode;

static struct {
	const char* name;
	size_t length;
} map[] = {
	{ STR_WITH_LEN("allow_surrogates") },
	{ STR_WITH_LEN("allow_noncharacters") },
	{ STR_WITH_LEN("allow_nonshortest") },
	{ STR_WITH_LEN("strict") },
	{ STR_WITH_LEN("loose") },
};

static void validate_parameter(pTHX_ const char* ptr, size_t len) {
	unsigned i;
	for (i = 0; i < sizeof map / sizeof *map; ++i) {
		if (map[i].length == len && memcmp(ptr, map[i].name, len) == 0)
			return;
	}
	Perl_croak(aTHX_ "Unknown argument to :utf8_strict: %*s", (int)len, ptr);
}
static void validate_parameters(pTHX_ SV* param) {
	STRLEN len;
	const char *begin, *delim;
	if (!param || !SvOK(param))
		return;

	begin = SvPV(param, len);
	delim = strchr(begin, ',');
	if (delim) {
		const char *end = begin + len;
		do {
			validate_parameter(aTHX_ begin, delim - begin);
			begin = delim + 1;
			delim = strchr(begin, ',');
		} while (delim);
		if (begin < end)
			validate_parameter(aTHX_ begin, end - begin);
	}
	else {
		validate_parameter(aTHX_ begin, len);
	}
}

#define line_buffered(flags) ((flags & (PERLIO_F_LINEBUF | PERLIO_F_CANWRITE)) == (PERLIO_F_LINEBUF | PERLIO_F_CANWRITE))

void PerlIOBase_flush_linebuf(pTHX) {
#ifdef dVAR
	dVAR;
#endif
	PerlIOl **table = &PL_perlio;
	PerlIOl *f;
	while ((f = *table)) {
		int i;
		table = (PerlIOl **) (f++);
		for (i = 1; i < 64; i++) {
			if (f->next && line_buffered(PerlIOBase(&(f->next))->flags))
				PerlIO_flush(&(f->next));
			f++;
		}
	}
}

static SSize_t read_from_next_layer(PerlIO *n, STDCHAR *dst, SSize_t fit) {
	SSize_t avail;

	if (fit <= 0)
		return 0;

	if (PerlIO_fast_gets(n)) {
		/*
		 * Layer below is also buffered. We do _NOT_ want to call its
		 * ->Read() because that will loop till it gets what we asked for
		 * which may hang on a pipe etc. Instead take anything it has to
		 * hand, or ask it to fill _once_.
		 */
		avail = PerlIO_get_cnt(n);
		if (avail <= 0) {
			avail = PerlIO_fill(n);
			if (avail == 0)
				avail = PerlIO_get_cnt(n);
			else {
				if (!PerlIO_error(n) && PerlIO_eof(n))
					avail = 0;
			}
		}
		if (avail > 0) {
			STDCHAR *ptr = PerlIO_get_ptr(n);
			const SSize_t cnt = avail;
			if (avail > fit)
				avail = fit;
			Copy(ptr, dst, avail, STDCHAR);
			PerlIO_set_ptrcnt(n, ptr + avail, cnt - avail);
		}
		return avail;
	}

	return PerlIO_read(n, dst, fit);
}

static IV fill_strict(pTHX_ PerlIO* f, PerlIOUnicode *u, PerlIOBuf *b, PerlIO *n) {
	SSize_t avail;
	SSize_t fit;
	STRLEN read_bytes = 0;
	STRLEN valid_bytes;
	const STRLEN carried = u->pending_length;

	/* Keep a split UTF-8 tail in b->buf and only compact when it reaches the end. */
	if (carried && u->pending_offset + carried == b->bufsiz) {
		Move(b->buf + u->pending_offset, b->buf, carried, STDCHAR);
		u->pending_offset = 0;
	}

	b->ptr = b->end = b->buf + u->pending_offset;
	b->end += carried;
	fit = (SSize_t)b->bufsiz - (SSize_t)(u->pending_offset + carried);

	avail = read_from_next_layer(n, b->end, fit);
	if (avail > 0)
		read_bytes = carried + avail;
	else
		read_bytes = carried;

	if (avail <= 0) {
		if (avail < 0 || (read_bytes == 0 && PerlIO_eof(n))) {
			PerlIOBase(f)->flags |= (avail == 0) ? PERLIO_F_EOF : PERLIO_F_ERROR;
			return -1;
		}
	}

	valid_bytes = validate_streaming(
		aTHX_ &u->stream,
		(const U8 *)(b->buf + u->pending_offset),
		read_bytes,
		carried,
		n
	);

	b->ptr = b->buf + u->pending_offset;
	b->end = b->ptr + valid_bytes;

	if (valid_bytes < read_bytes) {
		u->pending_offset += valid_bytes;
		u->pending_length = read_bytes - valid_bytes;
	}
	else {
		u->pending_offset = 0;
		u->pending_length = 0;
	}

	return 0;
}

static IV PerlIOUnicode_pushed(pTHX_ PerlIO* f, const char* mode, SV* arg, PerlIO_funcs* tab) {
	validate_parameters(aTHX_ arg);
	if (PerlIOBuf_pushed(aTHX_ f, mode, arg, tab) == 0) {
		PerlIOBase(f)->flags |= PERLIO_F_UTF8;
		PerlIOSelf(f, PerlIOUnicode)->pending_offset = 0;
		PerlIOSelf(f, PerlIOUnicode)->pending_length = 0;
		utf8_valid_stream_init(&PerlIOSelf(f, PerlIOUnicode)->stream);
		return 0;
	}
	return -1;
}

static IV PerlIOUnicode_fill(pTHX_ PerlIO* f) {
	PerlIOUnicode * const u = PerlIOSelf(f, PerlIOUnicode);
	PerlIOBuf * const b = &u->buf;
	PerlIO *n = PerlIONext(f);

	if (PerlIO_flush(f) != 0)
		return -1;
	if (PerlIOBase(f)->flags & PERLIO_F_TTY)
		PerlIOBase_flush_linebuf(aTHX);

	if (!b->buf)
		PerlIO_get_base(f);

	assert(b->buf);

	if (!PerlIOValid(n)) {
		PerlIOBase(f)->flags |= PERLIO_F_EOF;
		return -1;
	}

	if (fill_strict(aTHX_ f, u, b, n) != 0)
		return -1;

	PerlIOBase(f)->flags |= PERLIO_F_RDBUF;
	
	return 0;
}

PERLIO_FUNCS_DECL(PerlIO_utf8_strict) = {
	sizeof(PerlIO_funcs),
	"utf8_strict",
	sizeof(PerlIOUnicode),
	PERLIO_K_BUFFERED|PERLIO_K_UTF8,
	PerlIOUnicode_pushed,
	PerlIOBuf_popped,
	PerlIOBuf_open,
	PerlIOBase_binmode,
	NULL,
	PerlIOBase_fileno,
	PerlIOBuf_dup,
	PerlIOBuf_read,
	PerlIOBase_unread,
	PerlIOBuf_write,
	PerlIOBuf_seek,
	PerlIOBuf_tell,
	PerlIOBuf_close,
	PerlIOBuf_flush,
	PerlIOUnicode_fill,
	PerlIOBase_eof,
	PerlIOBase_error,
	PerlIOBase_clearerr,
	PerlIOBase_setlinebuf,
	PerlIOBuf_get_base,
	PerlIOBuf_bufsiz,
	PerlIOBuf_get_ptr,
	PerlIOBuf_get_cnt,
	PerlIOBuf_set_ptrcnt,
};

MODULE = PerlIO::utf8_strict

PROTOTYPES: DISABLE

BOOT:
	PerlIO_define_layer(aTHX_ (PerlIO_funcs*)&PerlIO_utf8_strict);
