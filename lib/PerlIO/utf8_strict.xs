#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#include "perliol.h"

#if 0
#define MAX_BYTES UTF8_MAXBYTES
#else
#define MAX_BYTES 4
#endif

typedef struct {
	PerlIOBuf buf;
	STDCHAR leftovers[MAX_BYTES];
	size_t leftover_length;
} PerlIOUnicode;

static IV PerlIOUnicode_pushed(pTHX_ PerlIO* f, const char* mode, SV* arg, PerlIO_funcs* tab) {
	if (PerlIOBuf_pushed(f, mode, arg, tab) == 0) {
		PerlIOBase(f)->flags |= PERLIO_F_UTF8;
		return 0;
	}
	return -1;
}

static IV PerlIOUnicode_fill(pTHX_ PerlIO* f) {
	PerlIOUnicode * const u = PerlIOSelf(f, PerlIOUnicode);
	PerlIOBuf * const b = &u->buf;
	PerlIO *n = PerlIONext(f);
	SSize_t avail;

	if (PerlIO_flush(f) != 0)
		return -1;
	if (PerlIOBase(f)->flags & PERLIO_F_TTY)
		PerlIOBase_flush_linebuf(aTHX);

	if (!b->buf)
		PerlIO_get_base(f);

	assert(b->buf);

	if (u->leftover_length) {
		Copy(u->leftovers, b->buf, u->leftover_length, STDCHAR);
		b->ptr = b->end = b->buf + u->leftover_length;
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
			Copy(ptr, b->ptr, avail, STDCHAR);
			PerlIO_set_ptrcnt(n, ptr + avail, cnt - avail);
		}
	}
	else {
		avail = PerlIO_read(n, b->ptr, fit);
	}
	if (avail <= 0) {
		PerlIOBase(f)->flags |= (avail == 0) ? PERLIO_F_EOF : PERLIO_F_ERROR;
		return -1;
	}
	is_utf8_string_loc(b->buf, avail + fit, (const U8**) &b->end);
	if (b->end < b->ptr + avail) {
		size_t len = b->ptr + avail - b->end;
		if (len >= MAX_BYTES || PerlIOBase(f)->flags & PERLIO_F_EOF)
			Perl_croak("Invalid unicode character");
		Copy(b->end, u->leftovers, len, char);
		u->leftover_length = len;
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

