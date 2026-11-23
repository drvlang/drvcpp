#include <iostream>

const char *message();

int main() {
    std::cout << "worker " << message() << '\n';
}
