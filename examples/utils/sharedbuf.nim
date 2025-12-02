# Manually managed byte buffer using `malloc` memory which is returned to the OS

from system/ansi_c import c_malloc, c_free

type SharedBuf* = object
  buf*: ptr UncheckedArray[byte]
  len*: int

proc create*(T: type SharedBuf, len: int): SharedBuf =
  SharedBuf(buf: cast[ptr UncheckedArray[byte]](c_malloc(len.csize_t)), len: len)

proc destroy*(v: var SharedBuf) =
  c_free(v.buf)
  v.buf.reset()

template data*(v: var SharedBuf): var openArray[byte] =
  v.buf.toOpenArray(0, v.len - 1)

template data*(v: SharedBuf): openArray[byte] =
  v.buf.toOpenArray(0, v.len - 1)
