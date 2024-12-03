function num(x) {
    return substr(x, 1, length(x) - 1)
}
BEGIN {
    print "static int fold1[][ 2 ] = {"
    i = 0
}
/ S;/ {print "  {0x" num($1) ", 0x" num($3) "},"}
/ C;/ {print "  {0x" num($1) ", 0x" num($3) "},"}
/ F;/ {
    if(match($5, /;$/)) {
        c[ i ] = $4
        d[ i ] = num($5)
    } else {
        c[ i ] = num($4)
        d[ i ] = 0
    }
    a[ i ] = num($1); b[ i++ ] = $3
}
END {
    print "};"
    print "static int fold2[][ 4 ] = {"
    for(j = 0; j < i; ++j) {
        print "  {0x" a[ j ] ", 0x" b[ j ] ", 0x" c[ j ] ", 0x" d[ j ] "},"
    }
    print "};"
}
