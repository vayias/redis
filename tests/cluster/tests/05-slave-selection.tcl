# Slave selection test
# Check the algorithm trying to pick the slave with the most complete history.

source "../tests/includes/init-tests.tcl"

# Create a cluster with 5 primary and 10 slaves, so that we have 2
# slaves for each primary.
test "Create a 5 nodes cluster" {
    create_cluster 5 10
}

test "Cluster is up" {
    assert_cluster_state ok
}

test "The first primary has actually two slaves" {
    assert {[llength [lindex [R 0 role] 2]] == 2}
}

test {Slaves of #0 are instance #5 and #10 as expected} {
    set port0 [get_instance_attrib redis 0 port]
    assert {[lindex [R 5 role] 2] == $port0}
    assert {[lindex [R 10 role] 2] == $port0}
}

test "Instance #5 and #10 synced with the primary" {
    wait_for_condition 1000 50 {
        [RI 5 primary_link_status] eq {up} &&
        [RI 10 primary_link_status] eq {up}
    } else {
        fail "Instance #5 or #10 primary link status is not up"
    }
}

set cluster [redis_cluster 127.0.0.1:[get_instance_attrib redis 0 port]]

test "Slaves are both able to receive and acknowledge writes" {
    for {set j 0} {$j < 100} {incr j} {
        $cluster set $j $j
    }
    assert {[R 0 wait 2 60000] == 2}
}

test "Write data while slave #10 is paused and can't receive it" {
    # Stop the slave with a multi/exec transaction so that the primary will
    # be killed as soon as it can accept writes again.
    R 10 multi
    R 10 debug sleep 10
    R 10 client kill 127.0.0.1:$port0
    R 10 deferred 1
    R 10 exec

    # Write some data the slave can't receive.
    for {set j 0} {$j < 100} {incr j} {
        $cluster set $j $j
    }

    # Prevent the primary from accepting new slaves.
    # Use a large pause value since we'll kill it anyway.
    R 0 CLIENT PAUSE 60000

    # Wait for the slave to return available again
    R 10 deferred 0
    assert {[R 10 read] eq {OK OK}}

    # Kill the primary so that a reconnection will not be possible.
    kill_instance redis 0
}

test "Wait for instance #5 (and not #10) to turn into a primary" {
    wait_for_condition 1000 50 {
        [RI 5 role] eq {primary}
    } else {
        fail "No failover detected"
    }
}

test "Wait for the node #10 to return alive before ending the test" {
    R 10 ping
}

test "Cluster should eventually be up again" {
    assert_cluster_state ok
}

test "Node #10 should eventually replicate node #5" {
    set port5 [get_instance_attrib redis 5 port]
    wait_for_condition 1000 50 {
        ([lindex [R 10 role] 2] == $port5) &&
        ([lindex [R 10 role] 3] eq {connected})
    } else {
        fail "#10 didn't became slave of #5"
    }
}

source "../tests/includes/init-tests.tcl"

# Create a cluster with 3 primary and 15 slaves, so that we have 5
# slaves for eatch primary.
test "Create a 3 nodes cluster" {
    create_cluster 3 15
}

test "Cluster is up" {
    assert_cluster_state ok
}

test "The first primary has actually 5 slaves" {
    assert {[llength [lindex [R 0 role] 2]] == 5}
}

test {Slaves of #0 are instance #3, #6, #9, #12 and #15 as expected} {
    set port0 [get_instance_attrib redis 0 port]
    assert {[lindex [R 3 role] 2] == $port0}
    assert {[lindex [R 6 role] 2] == $port0}
    assert {[lindex [R 9 role] 2] == $port0}
    assert {[lindex [R 12 role] 2] == $port0}
    assert {[lindex [R 15 role] 2] == $port0}
}

test {Instance #3, #6, #9, #12 and #15 synced with the primary} {
    wait_for_condition 1000 50 {
        [RI 3 primary_link_status] eq {up} &&
        [RI 6 primary_link_status] eq {up} &&
        [RI 9 primary_link_status] eq {up} &&
        [RI 12 primary_link_status] eq {up} &&
        [RI 15 primary_link_status] eq {up}
    } else {
        fail "Instance #3 or #6 or #9 or #12 or #15 primary link status is not up"
    }
}

proc primary_detected {instances} {
    foreach instance [dict keys $instances] {
        if {[RI $instance role] eq {primary}} {
            return true
        }
    }

    return false
}

test "New Primary down consecutively" {
    set instances [dict create 0 1 3 1 6 1 9 1 12 1 15 1]

    set loops [expr {[dict size $instances]-1}]
    for {set i 0} {$i < $loops} {incr i} {
        set primary_id -1
        foreach instance [dict keys $instances] {
            if {[RI $instance role] eq {primary}} {
                set primary_id $instance
                break;
            }
        }

        if {$primary_id eq -1} {
            fail "no primary detected, #loop $i"
        }

        set instances [dict remove $instances $primary_id]

        kill_instance redis $primary_id
        wait_for_condition 1000 50 {
            [primary_detected $instances]
        } else {
            failover "No failover detected when primary $primary_id fails"
        }

        assert_cluster_state ok
    }
}
