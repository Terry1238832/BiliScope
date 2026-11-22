// Declarations from <sys/kern_control.h>, which the iOS SDK does not expose to
// Swift. Used only to find the utun socket NetworkExtension opened.
#include <stdint.h>
#include <sys/types.h>

struct biliscope_ctl_info {
    uint32_t ctl_id;
    char ctl_name[96];
};

struct biliscope_sockaddr_ctl {
    unsigned char sc_len;
    unsigned char sc_family;
    uint16_t ss_sysaddr;
    uint32_t sc_id;
    uint32_t sc_unit;
    uint32_t sc_reserved[5];
};
