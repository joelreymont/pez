try:
    import _hashlib as _hashopenssl
except ImportError:
    _hashopenssl = None
    _openssl_md_meths = None
    from _operator import _compare_digest as compare_digest
else:
    _openssl_md_meths = frozenset(_hashopenssl.openssl_md_meth_names)
    compare_digest = _hashopenssl.compare_digest
import hashlib as _hashlib
