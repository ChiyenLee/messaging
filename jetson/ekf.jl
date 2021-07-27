using Revise
using julia_messaging
using quadruped_control
using quadruped_control: UnitQuaternion, RotXYZ
using LinearAlgebra
using EKF
using julia_messaging: writeproto, ZMQ
include("../EKF.jl/test/imu_grav_comp/imu_dynamics_discrete.jl")
## Subscribing example with ZMQ and Protobuf 
function main()
    # Subscribe to Vicon topics
    ctx = julia_messaging.ZMQ.Context(1)
	vicon = Vicon_msg()
	vicon_sub() = subscriber_thread(ctx,vicon,5000)
	vicon_thread = Task(vicon_sub)
	schedule(vicon_thread)

    # IMU readings 
    accel_imu = zeros(3);
    gyro_imu = zeros(3);

    # Timing 
    h = 0.005
    vicon_time = 0.0

    # Initialize EKF
    state_init = zeros(length(TrunkState)); state_init[7] = 1.0 
    state = TrunkState(state_init)
    vicon_init = zeros(7); vicon_init[4] = 1.0
    vicon_measurement = Vicon(vicon_init);
    input = ImuInput(zeros(length(ImuInput)))

    P = Matrix(1.0I(length(TrunkError))) * 1e10; 
    W = Matrix(1.0I(length(TrunkError))) * 1e-3;
    W[4:6, 4:6] .= I(3) * 1e-2 * h^2 
    W[end-5:end,end-5:end] = I(6)*1e2
    R = Matrix(1.0I(length(ViconError))) * 1e-3;
    ekf = ErrorStateFilter{TrunkState, TrunkError, ImuInput, Vicon, ViconError}(state, P, W, R) 

    # Publisher 
    ekf_pub = create_pub(ctx,5003, "*")
    imu_pub = create_pub(ctx,5002, "*")
    vicon_pub = create_pub(ctx,5001, "*")
    iob = PipeBuffer()
    ekf_msg = EKF_msg()
    imu_msg = IMU_msg()
    vicon_msg = Vicon_msg()

    try
        while true 
            A1Robot.getAcceleration(interface, accel_imu);
            A1Robot.getGyroscope(interface, gyro_imu); 

            # Prediction 
            input = ImuInput(accel_imu..., gyro_imu...)
            prediction!(ekf, input, h)

            # Update 
            if hasproperty(vicon, :quaternion)
               if vicon.time != vicon_time 
                    vicon_measurement = Vicon(vicon.position.x, vicon.position.y, vicon.position.z, vicon.quaternion.w, vicon.quaternion.x, vicon.quaternion.y, vicon.quaternion.z)
                    update!(ekf, vicon_measurement)
                    vicon_time = vicon.time

                    # Publishing 
                    setproperty!(vicon_msg, :quaternion, Quaternion_msg(w=vicon_measurement[4], 
                                x=vicon_measurement[5], y=vicon_measurement[6], z=vicon_measurement[4]))
                    setproperty!(vicon_msg, :position, Vector3_msg(x=vicon_measurement[1], y=vicon_measurement[2], z=vicon_measurement[3]))
                    setproperty!(vicon_msg, :time, time())
                    writeproto(iob, vicon_msg)
                    ZMQ.send(vicon_pub,take!(iob))
               end  
            end

            # Publishing
            r, v, q, α, β = getComponents(TrunkState(ekf.est_state))
            setproperty!(ekf_msg, :quaternion, Quaternion_msg(w=q[1],x=q[2], y=q[3], z=q[4]))
            setproperty!(ekf_msg, :position, Vector3_msg(x=r[1], y=r[2], z=r[3]))
            setproperty!(ekf_msg, :acceleration_bias, Vector3_msg(x=α[1], y=α[2], z=α[3]))
            setproperty!(ekf_msg, :angular_velocity_bias, Vector3_msg(x=β[1], y=β[2], z=β[3]))
            setproperty!(ekf_msg, :velocity, Vector3_msg(x=v[1], y=v[2], z=v[3]))
            setproperty!(ekf_msg, :time, time())
            writeproto(iob, ekf_msg)
			ZMQ.send(ekf_pub,take!(iob))

            setproperty!(imu_msg, :gyroscope, Vector3_msg(x=input[4],y=input[5], z=input[6]))
            setproperty!(imu_msg, :acceleration, Vector3_msg(x=input[1], y=input[2], z=input[3]))
            setproperty!(imu_msg, :time, time())
            writeproto(iob, imu_msg)
            ZMQ.send(imu_pub,take!(iob))
            

            sleep(h)
        end    
    catch e
        close(ctx)
        if e isa InterruptException
            # clean up 
            println("Process terminated by you")
            Base.throwto(vicon_thread, InterruptException())
        else 
            rethrow(e)
        end 
    end
end 

main()