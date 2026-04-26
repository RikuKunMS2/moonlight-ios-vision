#pragma once

#include <AudioToolbox/AudioToolbox.h>

#ifdef DEBUG
  #define DEBUG_TRACE( s, ... ) NSLog( @"<%@:%d> %@", [[NSString stringWithUTF8String:__FILE__] lastPathComponent], __LINE__,  [NSString stringWithFormat:(s), ##__VA_ARGS__] )
  #define DEBUG_CSTR( s, ... ) fprintf(stderr, (s), ##__VA_ARGS__);
#else
  #define DEBUG_TRACE( s, ... )
  #define DEBUG_CSTR( s, ... )
#endif

#ifdef __cplusplus
extern "C" {
#endif

static void CA_LogError(OSStatus error, const char *fmt, ...)
{
    char errorString[20];

    // See if it appears to be a 4-char-code
    *(uint32_t *)(errorString + 1) = CFSwapInt32HostToBig(error);
    if (isprint(errorString[1]) && isprint(errorString[2]) &&
        isprint(errorString[3]) && isprint(errorString[4])) {
        errorString[0] = errorString[5] = '\'';
        errorString[6] = '\0';
    }
    else {
        // No, format it as an integer
        snprintf(errorString, sizeof(errorString), "%d", (int)error);
    }

    char logBuffer[1024];
    va_list args;
    va_start(args, fmt);
    vsnprintf(logBuffer, sizeof(logBuffer), fmt, args);
    va_end(args);

    Log(LOG_E, @"CoreAudio Error: %s (%s)", logBuffer, errorString);
}

static void CA_FourCC(uint32_t value, char *outFormatIDStr)
{
    uint32_t formatID = CFSwapInt32HostToBig(value);
    bcopy(&formatID, outFormatIDStr, 4);
    outFormatIDStr[4] = '\0';
}

// based on mpv ca_print_asbd()
static void CA_PrintASBD(const char *description, const AudioStreamBasicDescription *asbd)
{
    char formatIDStr[5];
    CA_FourCC(asbd->mFormatID, formatIDStr);

    uint32_t flags = asbd->mFormatFlags;
    DEBUG_TRACE(@"%s %7.1fHz %u bit %s [%u bpp][%u fpp] [%u bpf][%u ch] %s %s %s%s%s%s\n",
                description, asbd->mSampleRate, asbd->mBitsPerChannel, formatIDStr,
                asbd->mBytesPerPacket, asbd->mFramesPerPacket,
                asbd->mBytesPerFrame, asbd->mChannelsPerFrame,
                (flags & kAudioFormatFlagIsFloat) ? "float" : "int",
                (flags & kAudioFormatFlagIsBigEndian) ? "BE" : "LE",
                (flags & kAudioFormatFlagIsFloat) ? ""
                : ((flags & kAudioFormatFlagIsSignedInteger) ? "S" : "U"),
                (flags & kAudioFormatFlagIsPacked) ? " packed" : "",
                (flags & kAudioFormatFlagIsAlignedHigh) ? " aligned" : "",
                (flags & kAudioFormatFlagIsNonInterleaved) ? " non-interleaved" : " interleaved");
}

// classic hex dump
static void CA_HexDump(const uint8_t *bytePtr, size_t length)
{
    size_t bytesToPrint = length;

    // Print 16 bytes per line
    for (size_t i = 0; i < bytesToPrint; i += 16) {
        printf("%08lx  ", (unsigned long)(bytePtr + i));

        // Print the hex values (32 bytes)
        for (size_t j = 0; j < 16 && (i + j) < bytesToPrint; ++j) {
            printf("%02x ", bytePtr[i + j]);
            if (j == 15) printf(" ");
        }

        printf(" |");

        for (size_t j = 0; j < 16 && (i + j) < bytesToPrint; ++j) {
            uint8_t byte = bytePtr[i + j];
            if (byte >= 32 && byte <= 126)
                printf("%c", byte);
            else
                printf(".");
        }

        printf("|\n");
    }
}

#ifdef __cplusplus
}
#endif
