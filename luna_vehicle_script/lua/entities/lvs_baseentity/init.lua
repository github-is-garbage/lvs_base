AddCSLuaFile( "shared.lua" )
AddCSLuaFile( "cl_init.lua" )
include("shared.lua")

function ENT:SpawnFunction( ply, tr, ClassName )

	if not tr.Hit then return end

	local ent = ents.Create( ClassName )
	ent:StoreCPPI( ply )
	ent:SetPos( tr.HitPos + tr.HitNormal * 15 )
	ent:Spawn()
	ent:Activate()

	return ent
end

function ENT:Initialize()
	self:SetModel( self.MDL )

	self:PhysicsInit( SOLID_VPHYSICS )
	self:SetMoveType( MOVETYPE_VPHYSICS )
	self:SetSolid( SOLID_VPHYSICS )
	self:SetUseType( SIMPLE_USE )
	self:SetRenderMode( RENDERMODE_TRANSALPHA )
	self:AddFlags( FL_OBJECT )

	local PObj = self:GetPhysicsObject()

	if not IsValid( PObj ) then 
		self:Remove()

		print("LVS: missing model. Vehicle terminated.")

		return
	end

	PObj:EnableMotion( false )
	PObj:EnableDrag( false )

	self:OnSpawn( PObj )

	self:StartMotionController()

	PObj:EnableMotion( true )

	self:PhysWake()

	self:AutoAI()
end

function ENT:AutoAI()
	if IsValid( self._OwnerEntLVS ) then
		if self._OwnerEntLVS:InVehicle() then
			if self._OwnerEntLVS:IsAdmin() then
				self:SetAI( true )
			end
		end
	end
end

function ENT:GetWorldGravity()
	local PhysObj = self:GetPhysicsObject()

	if not IsValid( PhysObj ) or not PhysObj:IsGravityEnabled() then return 0 end

	return physenv.GetGravity():Length()
end

function ENT:GetWorldUp()
	local Gravity = physenv.GetGravity()

	if Gravity:Length() > 0 then
		return -Gravity:GetNormalized()
	else
		return Vector(0,0,1)
	end
end

function ENT:GetStability()
	local ForwardVelocity = self:WorldToLocal( self:GetPos() + self:GetVelocity() ).x

	local Stability = math.Clamp(ForwardVelocity / self.MaxPerfVelocity,0,1) ^ 2
	local InvStability = 1 - Stability

	return Stability, InvStability, ForwardVelocity
end

function ENT:CalcAero( phys, deltatime )
	local WorldGravity = self:GetWorldGravity()
	local WorldUp = self:GetWorldUp()

	local Stability, InvStability, ForwardVelocity = self:GetStability()

	local Forward = self:GetForward()
	local Left = -self:GetRight()
	local Up = self:GetUp()

	local Vel = self:GetVelocity()
	local VelForward = Vel:GetNormalized()

	local PitchPull = math.max( (math.deg( math.acos( math.Clamp( WorldUp:Dot( Up ) ,-1,1) ) ) - 90) /  90, 0 )
	local YawPull = (math.deg( math.acos( math.Clamp( WorldUp:Dot( Left ) ,-1,1) ) ) - 90) /  90

	local StallPitchPull = (math.deg( math.acos( math.Clamp( -VelForward:Dot( Up ) ,-1,1) ) ) - 90) / 90
	local StallYawPull = (math.deg( math.acos( math.Clamp( -VelForward:Dot( Left ) ,-1,1) ) ) - 90) /  90

	local GravMul = WorldGravity / 600
	local GravityPitch = math.abs( PitchPull ) ^ 1.25 * self:Sign( PitchPull ) * GravMul * 0.25
	local GravityYaw = math.abs( YawPull ) ^ 1.25 * self:Sign( YawPull ) * GravMul * 0.25

	local StallMul = math.min( -math.min(Vel.z,0) / 1000, 1 ) * 10

	local StallPitch = math.abs( PitchPull ) * self:Sign( PitchPull ) * GravMul * StallMul
	local StallYaw = math.abs( YawPull ) * self:Sign( YawPull ) * GravMul * StallMul

	local Steer = self:GetSteer()
	local Pitch = math.Clamp(Steer.y - GravityPitch,-1,1) * self.TurnRatePitch * 3 * Stability - StallPitch * InvStability
	local Yaw = math.Clamp(Steer.z * 4 + GravityYaw,-1,1) * self.TurnRateYaw * 0.75 * Stability + StallYaw * InvStability
	local Roll = math.Clamp( self:Sign( Steer.x ) * (math.abs( Steer.x ) ^ 1.5) * 22,-1,1) * self.TurnRateRoll * 12 * Stability

	local VelL = self:WorldToLocal( self:GetPos() + Vel )

	local MulZ = (math.max( math.deg( math.acos( math.Clamp( VelForward:Dot( Forward ) ,-1,1) ) ) - self.MaxSlipAnglePitch * math.abs( Steer.y ), 0 ) / 90) * 0.3
	local MulY = (math.max( math.abs( math.deg( math.acos( math.Clamp( VelForward:Dot( Left ) ,-1,1) ) ) - 90 ) - self.MaxSlipAngleYaw * math.abs( Steer.z ), 0 ) / 90) * 0.15

	local Lift = -math.min( (math.deg( math.acos( math.Clamp( WorldUp:Dot( Up ) ,-1,1) ) ) - 90) / 180,0) * (WorldGravity / (1 / deltatime))

	return Vector(0, -VelL.y * MulY, Lift - VelL.z * MulZ ) * Stability,  Vector( Roll, Pitch, Yaw )
end

function ENT:PhysicsSimulate( phys, deltatime )
	local Aero, Torque = self:CalcAero( phys, deltatime )

	phys:Wake()

	local ForwardVelocity = self:WorldToLocal( self:GetPos() + self:GetVelocity() ).x
	local TargetVelocity = self.MaxVelocity * self:GetThrottle()

	local Thrust = Vector(math.max(TargetVelocity - ForwardVelocity,0),0,0) * self.MaxThrust

	local ForceLinear = (Aero * 10000 * self.ForceLinearMultiplier + Thrust) * deltatime
	local ForceAngle = (Torque * 25 * self.ForceAngleMultiplier - phys:GetAngleVelocity() * 1.5 * self.ForceAngleDampingMultiplier) * deltatime * 250

	return ForceAngle, ForceLinear, SIM_LOCAL_ACCELERATION
end

function ENT:OnSpawn( PObj )
	self:SetBodygroup( 14, 1 ) 
	self:SetBodygroup( 13, 1 ) 

	PObj:SetMass( 5000 )

	self:AddDriverSeat( Vector(32,0,67.5), Angle(0,-90,0) )
end

function ENT:Think()
	self:HandleActive()
	self:OnTick()

	self:NextThink( CurTime() )
	
	return true
end

function ENT:OnDriverChanged( Old, New, VehicleIsActive )
end

function ENT:OnGunnerChanged( Old, New )
end

function ENT:OnTick()
end

function ENT:HandleActive()
	local gPod = self:GetGunnerSeat()

	if IsValid( gPod ) then
		local Gunner = gPod:GetDriver()
		local OldGunner = self:GetGunner()

		if Gunner ~= self:GetGunner() then
			self:SetGunner( Gunner )
			self:OnGunnerChanged( OldGunner, Gunner )
		end
	end

	local Pod = self:GetDriverSeat()

	if not IsValid( Pod ) then
		self:SetActive( false )

		return
	end

	local Driver = Pod:GetDriver()
	local Active = self:GetActive()

	if Driver ~= self:GetDriver() then
		if self:GetlvsLockedStatus() then
			self:UnLock()
		end

		local NewDriver = Driver
		local OldDriver = self:GetDriver()
		local IsActive = IsValid( Driver )

		self:SetDriver( Driver )
		self:SetActive( IsActive )

		self:OnDriverChanged( OldDriver, NewDriver, IsActive )
	end
end

function ENT:OnRemove()
end

function ENT:Lock()
	if self:GetlvsLockedStatus() then return end

	self:SetlvsLockedStatus( true )
	self:EmitSound( "doors/latchlocked2.wav" )
end

function ENT:UnLock()
	if not self:GetlvsLockedStatus() then return end

	self:SetlvsLockedStatus( false )
	self:EmitSound( "doors/latchunlocked1.wav" )
end

function ENT:Use( ply )
	if not IsValid( ply ) then return end

	if self:GetlvsLockedStatus() then 

		self:EmitSound( "doors/default_locked.wav" )

		return
	end

	self:SetPassenger( ply )
end

function ENT:AlignView( ply )
	if not IsValid( ply ) then return end

	timer.Simple( FrameTime() * 2, function()
		if not IsValid( ply ) or not IsValid( self ) then return end
		local Ang = self:GetAngles()
		Ang.r = 0
		ply:SetEyeAngles( Ang )
	end)
end

function ENT:SetPassenger( ply )
	if not IsValid( ply ) then return end

	local AI = self:GetAI()
	local DriverSeat = self:GetDriverSeat()

	if IsValid( DriverSeat ) and not IsValid( DriverSeat:GetDriver() ) and not ply:KeyDown( IN_WALK ) and not AI then
		ply:EnterVehicle( DriverSeat )
	else
		local Seat = NULL
		local Dist = 500000

		for _, v in pairs( self:GetPassengerSeats() ) do
			if IsValid( v ) and not IsValid( v:GetDriver() ) then
				local cDist = (v:GetPos() - ply:GetPos()):Length()
				
				if cDist < Dist then
					Seat = v
					Dist = cDist
				end
			end
		end

		if IsValid( Seat ) then
			ply:EnterVehicle( Seat )
		else
			if IsValid( DriverSeat ) then
				if not IsValid( self:GetDriver() ) and not AI then
					ply:EnterVehicle( DriverSeat )
				end
			else
				self:EmitSound( "doors/default_locked.wav" )
			end
		end
	end
end

function ENT:AddDriverSeat( Pos, Ang )
	if IsValid( self:GetDriverSeat() ) then return end

	local Pod = ents.Create( "prop_vehicle_prisoner_pod" )

	if not IsValid( Pod ) then
		self:Remove()

		print("LVS: Failed to create driverseat. Vehicle terminated.")

		return
	else
		self:SetDriverSeat( Pod )

		local DSPhys = Pod:GetPhysicsObject()

		Pod:SetMoveType( MOVETYPE_NONE )
		Pod:SetModel( "models/nova/airboat_seat.mdl" )
		Pod:SetKeyValue( "vehiclescript","scripts/vehicles/prisoner_pod.txt" )
		Pod:SetKeyValue( "limitview", 0 )
		Pod:SetPos( self:LocalToWorld( Pos ) )
		Pod:SetAngles( self:LocalToWorldAngles( Ang ) )
		Pod:SetOwner( self )
		Pod:Spawn()
		Pod:Activate()
		Pod:SetParent( self )
		Pod:SetNotSolid( true )
		Pod:SetColor( Color( 255, 255, 255, 0 ) ) 
		Pod:SetRenderMode( RENDERMODE_TRANSALPHA )
		Pod:DrawShadow( false )
		Pod.DoNotDuplicate = true
		Pod:SetNWInt( "pPodIndex", 1 )

		if IsValid( DSPhys ) then
			DSPhys:EnableDrag( false ) 
			DSPhys:EnableMotion( false )
			DSPhys:SetMass( 1 )
		end

		self:DeleteOnRemove( Pod )

		self:TransferCPPI( Pod )
	end
end

function ENT:AddPassengerSeat( Pos, Ang )
	if not isvector( Pos ) or not isangle( Ang ) then return NULL end

	local Pod = ents.Create( "prop_vehicle_prisoner_pod" )

	if not IsValid( Pod ) then return NULL end

	Pod:SetMoveType( MOVETYPE_NONE )
	Pod:SetModel( "models/nova/airboat_seat.mdl" )
	Pod:SetKeyValue( "vehiclescript","scripts/vehicles/prisoner_pod.txt" )
	Pod:SetKeyValue( "limitview", 0 )
	Pod:SetPos( self:LocalToWorld( Pos ) )
	Pod:SetAngles( self:LocalToWorldAngles( Ang ) )
	Pod:SetOwner( self )
	Pod:Spawn()
	Pod:Activate()
	Pod:SetParent( self )
	Pod:SetNotSolid( true )
	Pod:SetColor( Color( 255, 255, 255, 0 ) ) 
	Pod:SetRenderMode( RENDERMODE_TRANSALPHA )

	Pod:DrawShadow( false )
	Pod.DoNotDuplicate = true

	self.pPodKeyIndex = self.pPodKeyIndex and self.pPodKeyIndex + 1 or 2

	Pod:SetNWInt( "pPodIndex", self.pPodKeyIndex )

	self:DeleteOnRemove( Pod )
	self:TransferCPPI( Pod )

	local DSPhys = Pod:GetPhysicsObject()
	if IsValid( DSPhys ) then
		DSPhys:EnableDrag( false ) 
		DSPhys:EnableMotion( false )
		DSPhys:SetMass( 1 )
	end

	if not istable( self.pSeats ) then self.pSeats = {} end

	table.insert( self.pSeats, Pod )

	return Pod
end

function ENT:OnTakeDamage( dmginfo )
	self:TakePhysicsDamage( dmginfo )
end

function ENT:PhysicsCollide( data, physobj )
end

function ENT:PlayAnimation( animation, playbackrate )
	playbackrate = playbackrate or 1

	local sequence = self:LookupSequence( animation )

	self:ResetSequence( sequence )
	self:SetPlaybackRate( playbackrate )
	self:SetSequence( sequence )
end

function ENT:UpdateTransmitState() 
	return TRANSMIT_ALWAYS
end

function ENT:StoreCPPI( owner )
	self._OwnerEntLVS = owner
end

function ENT:TransferCPPI( target )
	if not IsEntity( target ) or not IsValid( target ) then return end

	if not CPPI then return end

	local Owner = self._OwnerEntLVS

	if not IsEntity( Owner ) then return end

	if IsValid( Owner ) then
		target:CPPISetOwner( Owner )
	end
end

function ENT:GetMissileOffset()
	return self:OBBCenter()
end
