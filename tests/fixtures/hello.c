#include <stdio.h>
#include <string.h>

int main() {
    char input[64];

    printf("Enter password: ");
    if (fgets(input, sizeof(input), stdin) == NULL) {
        printf("FAIL\n");
        return 1;
    }

    // Strip trailing newline
    size_t len = strlen(input);
    if (len > 0 && input[len - 1] == '\n') {
        input[len - 1] = '\0';
    }

    if (strcmp(input, "secret123") == 0) {
        printf("OK\n");
        return 0;
    } else {
        printf("FAIL\n");
        return 1;
    }
}
