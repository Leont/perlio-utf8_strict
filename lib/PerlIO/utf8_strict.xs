#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#include "perliol.h"

#define MAX_BYTES 4

static const U8 xs_utf8_sequence_len[0x100] = {
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1, /* 0x00-0x0F */
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1, /* 0x10-0x1F */
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1, /* 0x20-0x2F */
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1, /* 0x30-0x3F */
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1, /* 0x40-0x4F */
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1, /* 0x50-0x5F */
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1, /* 0x60-0x6F */
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1, /* 0x70-0x7F */
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, /* 0x80-0x8F */
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, /* 0x90-0x9F */
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, /* 0xA0-0xAF */
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, /* 0xB0-0xBF */
    2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2, /* 0xC0-0xCF */
    2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2, /* 0xD0-0xDF */
    3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3, /* 0xE0-0xEF */
    4,4,4,4,4,0,0,0,0,0,0,0,0,0,0,0, /* 0xF0-0xFF */
};

static int is_complete(const U8* current, const U8* end) {
	return current + xs_utf8_sequence_len[*current] <= end;
}

typedef enum { STRICT_UTF8, ALLOW_SURROGATES, ALLOW_NONCHARACTERS, ALLOW_NONSHORTEST } utf8_flags;

static int is_valid(const U8* current, int flags) {
	size_t length = xs_utf8_sequence_len[*current];
	switch (length) {
		uint32_t v;
		case 0:
			return 0;
		case 1:
			return 1;
		case 2:
			/* 110xxxxx 10xxxxxx */
			if ((current[1] & 0xC0) != 0x80 ||
			  /* Non-shortest form */
			  current[0] < 0xC2)
				return 0;
			return 2;
		case 3:
			v = ((U32)current[0] << 16) | ((U32)current[1] <<  8) | ((U32)current[2]);
			/* 1110xxxx 10xxxxxx 10xxxxxx */
			if ((v & 0x00F0C0C0) != 0x00E08080 ||
			  /* Non-shortest form */
			  v < 0x00E0A080 ||
			  /* Surrogates U+D800..U+DFFF */
			  (v & 0x00EFA080) == 0x00EDA080 ||
			  /* Non-characters U+FDD0..U+FDEF, U+FFFE..U+FFFF */
			  (v >= 0x00EFB790 && (v <= 0x00EFB7AF || v >= 0x00EFBFBE)))
				return 0;
			return 3;
		case 4:
			v = ((U32)current[0] << 24)
			  | ((U32)current[1] << 16)
			  | ((U32)current[2] <<  8)
			  | ((U32)current[3]);
			/* 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx */
			if ((v & 0xF8C0C0C0) != 0xF0808080 ||
			  /* Non-shortest form */
			  v < 0xF0908080 ||
			  /* Greater than U+10FFFF */
			  v > 0xF48FBFBF ||
			  /* Non-characters U+nFFFE..U+nFFFF on plane 1-16 */
			  (v & 0x000FBFBE) == 0x000FBFBE)
				return 0;
			return 4;
	}
}

typedef struct {
	PerlIOBuf buf;
	STDCHAR leftovers[MAX_BYTES];
	size_t leftover_length;
	int flags;
} PerlIOUnicode;

static struct {
	const char* name;
	size_t length;
	utf8_flags value;
} map[] = {
	{ STR_WITH_LEN("allow_surrogates"), ALLOW_SURROGATES },
	{ STR_WITH_LEN("allow_noncharacters"), ALLOW_NONCHARACTERS },
	{ STR_WITH_LEN("allow_nonshortest"), ALLOW_NONSHORTEST },
	{ STR_WITH_LEN("strict"), 0 },
	{ STR_WITH_LEN("loose"), ALLOW_SURROGATES | ALLOW_NONCHARACTERS | ALLOW_NONSHORTEST },
};

static int lookup_parameter(pTHX_ const char* ptr, size_t len) {
	int i;
	for (i = 0; i < sizeof map / sizeof *map; ++i) {
		if (map[i].length == len && memcmp(ptr, map[i].name, len) == 0)
			return map[i].value;
	}
	Perl_croak(aTHX_ "Unknown argument to :utf8_strict: %*s", len, ptr);
}
static int parse_parameters(pTHX_ SV* param) {
	STRLEN len;
	if (!param || !SvOK(param))
		return 0;

	const char* begin = SvPV(param, len);
	const char* delim = strchr(begin, ',');
	if(delim) {
		int ret = 0;
		const char* end = begin + len;
		do {
			ret |= lookup_parameter(aTHX_ begin, delim - begin);
			begin = delim + 1;
			delim = strchr(begin, ',');
		} while (delim);
		if (begin < end)
			ret |= lookup_parameter(aTHX_ begin, end - begin);
		return ret;
	}
	else {
		return lookup_parameter(aTHX_ begin, len);
	}
}

static IV PerlIOUnicode_pushed(pTHX_ PerlIO* f, const char* mode, SV* arg, PerlIO_funcs* tab) {
	int flags = parse_parameters(aTHX_ arg);
	if (PerlIOBuf_pushed(aTHX_ f, mode, arg, tab) == 0) {
		PerlIOBase(f)->flags |= PERLIO_F_UTF8;
		PerlIOSelf(f, PerlIOUnicode)->flags = flags;
		return 0;
	}
	return -1;
}

static IV PerlIOUnicode_fill(pTHX_ PerlIO* f) {
	PerlIOUnicode * const u = PerlIOSelf(f, PerlIOUnicode);
	PerlIOBuf * const b = &u->buf;
	PerlIO *n = PerlIONext(f);
	SSize_t avail;
	Size_t read_bytes = 0;

	if (PerlIO_flush(f) != 0)
		return -1;
	if (PerlIOBase(f)->flags & PERLIO_F_TTY)
		PerlIOBase_flush_linebuf(aTHX);

	if (!b->buf)
		PerlIO_get_base(f);

	assert(b->buf);

	if (u->leftover_length) {
		Copy(u->leftovers, b->buf, u->leftover_length, STDCHAR);
		b->end = b->buf + u->leftover_length;
		read_bytes = u->leftover_length;
		u->leftover_length = 0;
	}
	else {
		b->ptr = b->end = b->buf;
	}
	const SSize_t fit = (SSize_t)b->bufsiz - (b->end - b->buf);

	if (!PerlIOValid(n)) {
		PerlIOBase(f)->flags |= PERLIO_F_EOF;
		return -1;
	}

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
			Copy(ptr, b->end, avail, STDCHAR);
			PerlIO_set_ptrcnt(n, ptr + avail, cnt - avail);
			read_bytes += avail;
		}
	}
	else {
		avail = PerlIO_read(n, b->ptr, fit);
		if (avail > 0)
			read_bytes += avail;
	}
	if (avail <= 0) {
		if (avail < 0 || read_bytes == 0 && PerlIO_eof(n)) {
			PerlIOBase(f)->flags |= (avail == 0) ? PERLIO_F_EOF : PERLIO_F_ERROR;
			return -1;
		}
	}
	STDCHAR* end = b->buf + read_bytes;
	b->end = b->buf;
	while (b->end < end) {
		if (is_complete((const U8*)b->end, (const U8*)end)) {
			int len = is_valid((const U8 *)b->end, u->flags);
			if (len)
				b->end += len;
			else 
				Perl_croak(aTHX_ "Invalid unicode character");
		}
		else if (PerlIO_eof(n))
			Perl_croak(aTHX_ "Invalid unicode character at file end");
		else {
			size_t len = b->buf + read_bytes - b->end;
			Copy(b->end, u->leftovers, len, char);
			u->leftover_length = len;
			break;
		}
	}
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
	PerlIOBuf_unread,
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

BOOT:
	PerlIO_define_layer(aTHX_ &PerlIO_utf8_strict);

