/* pattern_scan.c
 *
 * Masked byte-pattern scanner used by PoE2MemoryReader.ahk as embedded
 * machine code (MCode). The interpreted AHK scan loop paid one DllCall per
 * anchor-byte candidate, which needed minutes for the ~45 MB PoE2 .text
 * region; this native version finishes in ~100 ms.
 *
 * Build (the hex string in PoE2MemoryReader._GetNativeScanner comes from):
 *   x86_64-w64-mingw32-gcc -O2 -c pattern_scan.c -o scan_w64.o
 *   objcopy -O binary --only-section=.text scan_w64.o scan_w64.bin
 *   od -An -v -tx1 scan_w64.bin | tr -d ' \n'
 *
 * The result must be fully position-independent: no imports, no RIP-relative
 * data references (verify with objdump -dr that .text has no relocations).
 *
 * Returns the number of matches found (up to maxMatches) and writes the
 * 0-based buffer offsets into out. mask[j] != 0 means pat[j] must match.
 */
long long pattern_scan(const unsigned char *buf, long long bufLen,
                       const unsigned char *pat, const unsigned char *mask,
                       long long patLen, long long *out, long long maxMatches)
{
    long long count = 0;
    long long i, j, last, j0;

    if (patLen <= 0 || bufLen < patLen || maxMatches < 1)
        return 0;

    /* first masked byte as cheap anchor */
    j0 = -1;
    for (j = 0; j < patLen; j++) {
        if (mask[j]) { j0 = j; break; }
    }
    if (j0 < 0)
        return 0;

    last = bufLen - patLen;
    for (i = 0; i <= last; i++) {
        if (buf[i + j0] != pat[j0])
            continue;
        for (j = 0; j < patLen; j++) {
            if (mask[j] && buf[i + j] != pat[j])
                goto next;
        }
        out[count++] = i;
        if (count >= maxMatches)
            return count;
next:   ;
    }
    return count;
}
