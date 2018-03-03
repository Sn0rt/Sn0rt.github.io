#!/usr/bin/perl

use 5.010;
use strict;
use utf8;

binmode STDIN, ':utf8';
binmode STDOUT, ':utf8';

while (<>) {
    # \p{Han} ~ [\x{4e00}-\x{9fa5}\x{3040}-\x{30FF}] + Punctuations.
    s/([\x{4e00}-\x{9fa5}\x{3040}-\x{30FF}])([a-zA-Z0-9@#&=\[\$\%\^\-\+\(\/\\])/\1 \2/g;
    s/([a-zA-Z0-9!#&;=\]\,\.\:\?\$\%\^\-\+\)\/\\])([\x{4e00}-\x{9fa5}\x{3040}-\x{30FF}])/\1 \2/g;
    print;
    next;
}
