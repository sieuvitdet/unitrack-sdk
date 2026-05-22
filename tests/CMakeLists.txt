add_executable(unitrack_tests core_tests.cpp)
target_link_libraries(unitrack_tests PRIVATE unitrack)
target_include_directories(unitrack_tests PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../core/include
)
add_test(NAME core_tests COMMAND unitrack_tests)

# End-to-end test: spawns the Node backend and verifies events flow.
add_executable(unitrack_e2e e2e_test.cpp)
target_link_libraries(unitrack_e2e PRIVATE unitrack)
target_include_directories(unitrack_e2e PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../core/include
)
add_test(NAME e2e_test
    COMMAND unitrack_e2e
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}/..)
