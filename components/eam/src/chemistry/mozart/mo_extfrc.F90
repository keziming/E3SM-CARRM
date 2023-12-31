module mo_extfrc
  !---------------------------------------------------------------
  ! 	... insitu forcing module
  !---------------------------------------------------------------

  use shr_kind_mod, only : r8 => shr_kind_r8
  use ppgrid,       only : pcols, begchunk, endchunk, pver, pverp
  use chem_mods,    only : gas_pcnst, extcnt
  use spmd_utils,   only : masterproc,iam
  use cam_abortutils,   only : endrun
  use cam_history,  only : addfld, horiz_only, outfld, add_default
  use cam_logfile,  only : iulog
  use tracer_data,  only : trfld,trfile
  use phys_grid,    only : get_rlat_all_p, get_rlon_all_p
  use time_manager,  only: get_curr_date
  implicit none

  type :: forcing
     integer           :: frc_ndx
     real(r8)              :: mw
     character(len=265) :: filename
     real(r8), pointer     :: times(:)
     real(r8), pointer     :: levi(:)
     character(len=8)  :: species
     character(len=8)  :: units
     integer                   :: nsectors
     character(len=32),pointer :: sectors(:)
     type(trfld), pointer      :: fields(:)
     type(trfile)              :: file
  end type forcing

  private
  public  :: extfrc_inti
  public  :: extfrc_set
  public  :: extfrc_timestep_init

  save

  integer, parameter :: time_span = 1

  character(len=256) ::   filename

  logical :: has_extfrc(gas_pcnst)
  type(forcing), allocatable  :: forcings(:)
  integer :: extfrc_cnt = 0
  integer, parameter :: nfire = 2 !! two type of fire emission
  integer :: nfire_count
  integer :: PH_emis_m(nfire), PH_emis_n(nfire) ! fire emission indices
  logical, parameter :: plumerise = .true.
contains

  subroutine extfrc_inti( extfrc_specifier, extfrc_type, extfrc_cycle_yr, extfrc_fixed_ymd, extfrc_fixed_tod)

    !-----------------------------------------------------------------------
    ! 	... initialize the surface forcings
    !-----------------------------------------------------------------------
    use cam_pio_utils, only : cam_pio_openfile
    use pio, only : pio_inq_dimid, pio_inquire, pio_inq_varndims, pio_closefile, &
         pio_inq_varname, pio_nowrite, file_desc_t
    use pio,              only : pio_inq_vardimid !(zhang73)
    use mo_tracname,   only : solsym
    use mo_chem_utls,  only : get_extfrc_ndx, get_spc_ndx
    use chem_mods,     only : frc_from_dataset
    use tracer_data,   only : trcdata_init
    use phys_control,  only : phys_getopts
    use physics_buffer, only : physics_buffer_desc

    implicit none

    !-----------------------------------------------------------------------
    ! 	... dummy arguments
    !-----------------------------------------------------------------------
    character(len=*), dimension(:), intent(in) :: extfrc_specifier
    character(len=*), intent(in) :: extfrc_type
    integer  , intent(in)        :: extfrc_cycle_yr
    integer  , intent(in)        :: extfrc_fixed_ymd
    integer  , intent(in)        :: extfrc_fixed_tod

    !-----------------------------------------------------------------------
    ! 	... local variables
    !-----------------------------------------------------------------------
    integer :: astat
    integer :: j, l, m, n, i,mm                          ! Indices
    character(len=16)  :: species
    character(len=16)  :: spc_name
    character(len=256) :: locfn
    character(len=256) :: spc_fnames(gas_pcnst)

    integer ::  vid, ndims, nvars, isec, ierr
    integer :: dimids(8), did, dimid,ncol_dimid,lat_dimid,time_dimid !(zhang73)
    integer, allocatable :: finddim_time(:), finddim_lat_ncol(:) !(zhang73) 
    type(file_desc_t) :: ncid
    character(len=32)  :: varname

    character(len=1), parameter :: filelist = ''
    character(len=1), parameter :: datapath = ''
    logical         , parameter :: rmv_file = .false.
    logical  :: history_aerosol      ! Output the MAM aerosol tendencies
    logical  :: history_verbose      ! produce verbose history output

    !-----------------------------------------------------------------------
 
    call phys_getopts( history_aerosol_out        = history_aerosol, &
                       history_verbose_out        = history_verbose   )

    do i = 1, gas_pcnst
       has_extfrc(i) = .false.
       spc_fnames(i) = ''
    enddo

    !-----------------------------------------------------------------------
    ! 	... species has insitu forcing ?
    !-----------------------------------------------------------------------

    !write(iulog,*) 'Species with insitu forcings'

    count_emis: do n=1,gas_pcnst

       if ( len_trim(extfrc_specifier(n) ) == 0 ) then
          exit count_emis
       endif

       i = scan(extfrc_specifier(n),'->')
       spc_name = trim(adjustl(extfrc_specifier(n)(:i-1)))
       filename = trim(adjustl(extfrc_specifier(n)(i+2:)))

       m = get_extfrc_ndx( spc_name )

       if ( m < 1 ) then
          call endrun('extfrc_inti: '//trim(spc_name)// ' does not have an external source')
       endif

       if ( .not. frc_from_dataset(m) ) then
          call endrun('extfrc_inti: '//trim(spc_name)//' cannot have external forcing from additional dataset')
       endif

       mm = get_spc_ndx(spc_name)
       spc_fnames(mm) = filename

       has_extfrc(mm) = .true.
       !write(iulog,*) '   ',  spc_name ,' : filename = ',trim(spc_fnames(mm)),' spc ndx = ',mm

    enddo count_emis

    extfrc_cnt = count( has_extfrc(:) )

    if( extfrc_cnt < 1 ) then
       if (masterproc) write(iulog,*) 'There are no species with insitu forcings'
       return
    end if

    if (masterproc) write(iulog,*) ' '

    !-----------------------------------------------------------------------
    ! 	... allocate forcings type array
    !-----------------------------------------------------------------------
    allocate( forcings(extfrc_cnt), stat=astat )
    if( astat/= 0 ) then
       write(iulog,*) 'extfrc_inti: failed to allocate forcings array; error = ',astat
       call endrun
    end if

    !-----------------------------------------------------------------------
    ! 	... setup the forcing type array
    !-----------------------------------------------------------------------
    n = 0
    species_loop : do m = 1,gas_pcnst
       has_forcing : if( has_extfrc(m) ) then
          spc_name = trim( solsym(m) )
          n        = n + 1
          !-----------------------------------------------------------------------
          ! 	... default settings
          !-----------------------------------------------------------------------
          forcings(n)%frc_ndx          = get_extfrc_ndx( spc_name )
          forcings(n)%species          = spc_name
          forcings(n)%filename         = spc_fnames(m)
          call addfld( trim(spc_name)//'_XFRC', (/ 'lev' /), 'A',  'molec/cm3/s', &
                       'external forcing for '//trim(spc_name) )
          call addfld( trim(spc_name)//'_CLXF', horiz_only, 'A',  'molec/cm2/s', &
                       'vertically intergrated external forcing for '//trim(spc_name) )
          if ( history_aerosol ) then 
             if (history_verbose) call add_default( trim(spc_name)//'_XFRC', 1, ' ' )
             call add_default( trim(spc_name)//'_CLXF', 1, ' ' )
          endif
       end if has_forcing
    end do species_loop
    !plume-rise diagnose
    if (plumerise) then
       !call addfld( 'bc_a4_EM_XFRC', (/ 'lev' /), 'A',  'molec/cm3/s', &
       !                'external forcing for UCI emis before plumerise' )
       !call addfld( 'bc_a4_EM_PH_XFRC', (/ 'lev' /), 'A',  'molec/cm3/s', &
       !                'external forcing for UCI emis after plumerise' )
       call addfld( 'plume_height_EM', horiz_only, 'I',  'meter', &
                       'plumerise height caused by EM fires' ) 
       call addfld( 'zmidr_ph', (/ 'lev' /), 'I',  'km', &
                       'midpoint geopotential in km realitive to surf' )
       call addfld( 'pmid_ph', (/ 'lev' /), 'I',  'Pa', &
                       'midpoint pressures (Pa)' )
       call addfld( 'tfld_ph', (/ 'lev' /), 'I',  'K', &
                       'midpoint temperature (K)' )
       call addfld( 'relhum_ph', (/ 'lev' /), 'I',  'unitless', &
                       'relative humidity' )
       call addfld( 'qh2o_ph', (/ 'lev' /), 'I',  'kg/kg', &
                       'specific humidity' ) 
       call addfld( 'ufld_ph', (/ 'lev' /), 'I',  'm/s', &
                       'zonal velocity (m/s)' )
       call addfld( 'vfld_ph', (/ 'lev' /), 'I',  'm/s', &
                       'meridional velocity (m/s)' )
       
    endif
    !---------------------------------------------------------------------
    if (masterproc) then
       !-----------------------------------------------------------------------
       ! 	... diagnostics
       !-----------------------------------------------------------------------
       write(iulog,*) ' '
       write(iulog,*) 'extfrc_inti: diagnostics'
       write(iulog,*) ' '
       write(iulog,*) 'extfrc timing specs'
       write(iulog,*) 'type = ',extfrc_type
       if( extfrc_type == 'FIXED' ) then
          write(iulog,*) ' fixed date = ', extfrc_fixed_ymd
          write(iulog,*) ' fixed time = ', extfrc_fixed_tod
       else if( extfrc_type == 'CYCLICAL' ) then
          write(iulog,*) ' cycle year = ',extfrc_cycle_yr
       end if
       write(iulog,*) ' '
       write(iulog,*) 'there are ',extfrc_cnt,' species with external forcing files'
       do m = 1,extfrc_cnt
          write(iulog,*) ' '
          write(iulog,*) 'forcing type ',m
          write(iulog,*) 'species = ',trim(forcings(m)%species)
          write(iulog,*) 'frc ndx = ',forcings(m)%frc_ndx
          write(iulog,*) 'filename= ',trim(forcings(m)%filename)
       end do
       write(iulog,*) ' '
    endif

    !-----------------------------------------------------------------------
    ! read emis files to determine number of sectors
    !-----------------------------------------------------------------------
    PH_emis_m(:) = -1 ! fire emission type
    PH_emis_n(:) = -1 ! fire emission sector 
    nfire_count = 0 ! fire emission counted
    frcing_loop: do m = 1, extfrc_cnt

       forcings(m)%nsectors = 0

       call cam_pio_openfile ( ncid, trim(forcings(m)%filename), PIO_NOWRITE)
       ierr = pio_inquire (ncid, nVariables=nvars)

       allocate(finddim_time(nvars))
       allocate(finddim_lat_ncol(nvars))
       finddim_time=0
       finddim_lat_ncol=0
       time_dimid=-9999
       lat_dimid=-9999
       ncol_dimid=-9999

       ierr = pio_inq_dimid(ncid, 'time', dimid)
       if(ierr==0) time_dimid = dimid
       ierr = pio_inq_dimid(ncid, 'lat', dimid)
       if(ierr==0) lat_dimid = dimid
       ierr = pio_inq_dimid(ncid, 'ncol', dimid)
       forcings(m)%file%is_ncol = (ierr==0)
       if(ierr==0) ncol_dimid = dimid
       if(masterproc) write(iulog,*) '(zhang73 extfrc_inti) time_dimid, lat_dimid, ncol_dimid=',time_dimid, lat_dimid, ncol_dimid

       do vid = 1,nvars

          ierr = pio_inq_varndims (ncid, vid, ndims)

          ierr = pio_inq_vardimid (ncid, vid, dimids(1:ndims)) !(zhang73)
          do did=1,ndims
             if( dimids(did) == time_dimid ) finddim_time(vid)=1
             if(  dimids(did) == lat_dimid ) finddim_lat_ncol(vid)=1
             if( dimids(did) == ncol_dimid ) finddim_lat_ncol(vid)=1
          enddo

          ierr = pio_inq_varname (ncid, vid, varname)
          if( finddim_time(vid)==1 .and. finddim_lat_ncol(vid)==1)then !(zhang73)
             !write(iulog,*) '(zhang73 extfrc_inti) valid var: finddim_time(vid), finddim_lat_ncol(vid)=',trim(varname),finddim_time(vid), finddim_lat_ncol(vid)
             forcings(m)%nsectors = forcings(m)%nsectors+1
             ! kzm note: here assumes fire emission are in ncol emission files 
             if (plumerise)then
                !if (trim(forcings(m)%species) == 'bc_a4' .and. trim(varname) == 'EM')then
                if (trim(varname) == 'EM')then
                   nfire_count = nfire_count +1
                   if(masterproc) write(iulog,*) forcings(m)%species
                   if(masterproc) write(iulog,*) 'sector number = ', forcings(m)%nsectors
                   if(masterproc) write(iulog,*) 'UCI wildfire emission in model type ', nfire_count
                   PH_emis_m(nfire_count) = m
                   PH_emis_n(nfire_count) = forcings(m)%nsectors
                   if(masterproc) write(iulog,*) 'PH_emis_m', PH_emis_m(nfire_count)
                   if(masterproc) write(iulog,*) 'PH_emis_n', PH_emis_n(nfire_count)

                end if
             endif
          else
             !write(iulog,*) 'extfrc_inti: Skipping variable ', trim(varname),', ndims = ',ndims,' , species=',trim(forcings(m)%species)
          end if
       enddo

       allocate( forcings(m)%sectors(forcings(m)%nsectors), stat=astat )
       if( astat/= 0 ) then
         write(iulog,*) 'extfrc_inti: failed to allocate forcings(m)%sectors array; error = ',astat
         call endrun
       end if

       isec = 1
       do vid = 1,nvars

          ierr = pio_inq_varndims (ncid, vid, ndims)
!          if( ndims == dim_thres ) then !(zhang73) check ndims from 4 -> 3 to activate bc_a4_ncol
          if( finddim_time(vid)==1 .and. finddim_lat_ncol(vid)==1)then !(zhang73)
             ierr = pio_inq_varname(ncid, vid, forcings(m)%sectors(isec))
             isec = isec+1
          endif

       enddo
       deallocate(finddim_time)
       deallocate(finddim_lat_ncol)

       call pio_closefile (ncid)

       allocate(forcings(m)%file%in_pbuf(size(forcings(m)%sectors)))
       forcings(m)%file%in_pbuf(:) = .false.
       call trcdata_init( forcings(m)%sectors, &
                          forcings(m)%filename, filelist, datapath, &
                          forcings(m)%fields,  &
                          forcings(m)%file, &
                          rmv_file, extfrc_cycle_yr, extfrc_fixed_ymd, extfrc_fixed_tod, extfrc_type)

    enddo frcing_loop


  end subroutine extfrc_inti

  subroutine extfrc_timestep_init( pbuf2d, state )
    !-----------------------------------------------------------------------
    !       ... check serial case for time span
    !-----------------------------------------------------------------------

    use physics_types,only : physics_state
    use ppgrid,       only : begchunk, endchunk
    use tracer_data,  only : advance_trcdata
    use physics_buffer, only : physics_buffer_desc

    implicit none

    type(physics_state), intent(in):: state(begchunk:endchunk)                 
    type(physics_buffer_desc), pointer :: pbuf2d(:,:)

    !-----------------------------------------------------------------------
    !       ... local variables
    !-----------------------------------------------------------------------
    integer :: m

    do m = 1,extfrc_cnt
       call advance_trcdata( forcings(m)%fields, forcings(m)%file, state, pbuf2d  )
    end do

  end subroutine extfrc_timestep_init

 ! subroutine extfrc_set( lchnk, zint, frcing, ncol )
  subroutine extfrc_set( lchnk, zint, frcing, ncol, &
                         zmidr, pmid, tfld, relhum, qh2o, ufld, vfld )
   
    !--------------------------------------------------------
    !	... form the external forcing
    !--------------------------------------------------------

    implicit none

    !--------------------------------------------------------
    !	... dummy arguments
    !--------------------------------------------------------
    integer,  intent(in)    :: ncol                  ! columns in chunk
    integer,  intent(in)    :: lchnk                 ! chunk index
    real(r8), intent(in)    :: zint(ncol, pverp)                  ! interface geopot above surface (km)
    real(r8), intent(inout) :: frcing(ncol,pver,extcnt)   ! insitu forcings (molec/cm^3/s)
    ! plume-rise parameters
    real(r8), intent(in)  ::   zmidr(ncol,pver)             ! midpoint geopot height - elevation ( km )
    real(r8), intent(in)  ::   pmid(pcols,pver)            ! midpoint pressure (Pa)
    real(r8), intent(in)  ::   tfld(pcols,pver)            ! midpoint temperature (K)
    real(r8), intent(in)  ::   relhum(ncol,pver)           ! relative humidity (0~1)
    real(r8), intent(in)  ::   qh2o(pcols,pver)            ! specific humidity (kg/kg)
    real(r8), intent(in)  ::   ufld(pcols,pver)            ! zonal velocity (m/s)
    real(r8), intent(in)  ::   vfld(pcols,pver)            ! meridional velocity (m/s)
    !--------------------------------------------------------
    !	... local variables
    !--------------------------------------------------------
    integer  ::  i, m, n
    character(len=16) :: xfcname
    real(r8) :: frcing_col(1:ncol)
    integer  :: k, isec
    real(r8),parameter :: km_to_cm = 1.e5_r8
    integer :: icol ! plumerise
    !------------------------------------------------------
    !    ... plume_height variables
    !-----------------------------------------------------
    logical :: fire_detected
    real(r8) :: plume_height,emis_col
    real(r8) :: plume_height_EM(ncol), pt_v(pver)
    integer :: ph_z(ncol), fire_icol   ! index of levels of max plume height
    real(r8) :: frcing_col_plume,frcing_vertical_plume_old(pver),frcing_vertical_plume_new(pver)
    real(r8) :: clat(pcols)                   ! current latitudes(radians)
    real(r8) :: clon(pcols)                   ! current longitudes(radians)
    real(r8) :: tl ! local time
    integer :: iyear,imo,iday_m,tod
    if( extfrc_cnt < 1 .or. extcnt < 1 ) then
       return
    end if
    call get_rlat_all_p(lchnk, ncol, clat)
    call get_rlon_all_p(lchnk, ncol, clon)
    call get_curr_date (iyear,imo,iday_m,tod)
    !--------------------------------------------------------
    !	... set non-zero forcings
    !--------------------------------------------------------
    src_loop : do m = 1,extfrc_cnt

      n = forcings(m)%frc_ndx

       frcing(:ncol,:,n) = 0._r8
       do isec = 1,forcings(m)%nsectors
          ! move this part to the bottom of the loop ---------------
          !if (forcings(m)%file%alt_data) then
          !   frcing(:ncol,:,n) = frcing(:ncol,:,n) + forcings(m)%fields(isec)%data(:ncol,pver:1:-1,lchnk)
          !else
          !   frcing(:ncol,:,n) = frcing(:ncol,:,n) + forcings(m)%fields(isec)%data(:ncol,:,lchnk)
          !endif
          !----------------------------------------------------------

          !check wildfire emission EM
          if ((plumerise) .and. (forcings(m)%file%alt_data)) then
             fire_detected = .false.
             fire_icol = -1
             if ((m == PH_emis_m(1) .and. isec == PH_emis_n(1)) .or. (m == PH_emis_m(2) .and. isec == PH_emis_n(2)))then
                plume_height_EM(:ncol) = 0._r8
                frcing_col_plume = 0._r8
                frcing_vertical_plume_old(:pver) = 0._r8
                frcing_vertical_plume_new(:pver) = 0._r8
                do icol=1,pcols ! calculate if EM emitted
                   emis_col = sum(forcings(m)%fields(isec)%data(icol,:,lchnk))
                   if ( emis_col  > 0.0_r8) then
                         fire_detected = .true.
                         fire_icol = icol
                         write(iulog,*) 'kzm_fire_species ', forcings(m)%species, isec
                         write(iulog,*)'kzm_plume_rise_calculation_running'
                         write(iulog,*)'kzm_plume_rise_calculation_lat ', clat(icol)/(3.1415_r8)*180.0_r8
                         write(iulog,*)'kzm_plume_rise_calculation_lon ', clon(icol)/(3.1415_r8)*180.0_r8
                         call cal_plume_height(plume_height,zmidr(icol,:), pmid(icol,:), &
                                 tfld(icol,:), relhum(icol,:), qh2o(icol,:), ufld(icol,:), &
                                 vfld(icol,:), clat(icol)/(3.1415_r8)*180.0_r8, clon(icol)/(3.1415_r8)*180.0_r8, tl, pt_v)
                         plume_height_EM(icol) = plume_height ! in meter
                         write(iulog,*)'kzm_plume_time ', iyear,imo,iday_m,tod
                         write(iulog,*)'kzm_plume_height ', plume_height, 'local time ',tl 
                         !write(iulog,*)'kzm_plume environment data begin: zmidr pmid tfld relhum qh2o ufld vfld '
                         !do k = pver,30,-1
                         !   write(iulog,*)k, zmidr(icol,k) ,pmid(icol,k), pt_v(k), relhum(icol,k), qh2o(icol,k), ufld(icol,k),vfld(icol,k)  
                         !enddo
                         !write(iulog,*)'kzm_plume environment data end'
                         ! match plume height to model vertical grid
                         ph_z(icol) = pver
                         do k = 2, pver
                            if ((plume_height - zmidr(icol,k)*1000_r8) > 0._r8 .and. (plume_height - zmidr(icol,k-1)*1000_r8 < 0._r8)) then
                               ph_z(icol) = k
                            endif 
                         enddo 
                         write(iulog,*)'kzm_plume_layer ', ph_z(icol)
                         ! reset the forcing
                         ! get initial emission from forcing data
                         frcing_vertical_plume_old(1:pver) = forcings(m)%fields(isec)%data(icol,pver:1:-1,lchnk) ! reverse
                         ! calculate the total emission in this column
                         do k = 1,pver
                            frcing_col_plume = frcing_col_plume +  &
                                                     frcing_vertical_plume_old(k)*(zint(icol,k)-zint(icol,k+1))*km_to_cm
                           ! write(iulog,*)'kzm_level ',k, 'old emis ', frcing_vertical_plume_old(k)
                         enddo
                         ! redistrict the emission
                         do k = 1,pver
                            ! option: release all emission into plume top layer
                            if (k == ph_z(icol)) then
                               frcing_vertical_plume_new(k) =  frcing_col_plume/(abs(zint(icol,k)-zint(icol,k+1))*km_to_cm)
                            else
                               frcing_vertical_plume_new(k) =  0.0_r8 
                            endif                               

                            ! option: release emission evenly from plume top to surface 
                            !if (k >= ph_z(icol)) then
                            !   frcing_vertical_plume_new(k) =  frcing_col_plume/(abs(zint(icol,pver+1)-zint(icol,ph_z(icol)))*km_to_cm)
                            !else
                            !   frcing_vertical_plume_new(k) = 0.0_r8
                            !endif
                            !write(iulog,*)'kzm_level ',k, 'new emis ', frcing_vertical_plume_new(k) 
                         enddo 
                         forcings(m)%fields(isec)%data(icol,:,lchnk) = frcing_vertical_plume_new(pver:1:-1) ! reverse back    
                         write(iulog,*)'kzm_fire_forcing_data_finished '
                     end if
                  enddo 
                endif ! if fire emission released 
            endif !plumerise flag   

            ! back to no fire plume calculation 
            ! add emission from different sectors together
            if (forcings(m)%file%alt_data) then
               frcing(:ncol,:,n) = frcing(:ncol,:,n) + forcings(m)%fields(isec)%data(:ncol,pver:1:-1,lchnk)
            else
               frcing(:ncol,:,n) = frcing(:ncol,:,n) + forcings(m)%fields(isec)%data(:ncol,:,lchnk)
            endif
       enddo

       xfcname = trim(forcings(m)%species)//'_XFRC'
       call outfld( xfcname, frcing(:ncol,:,n), ncol, lchnk )

       frcing_col(:ncol) = 0._r8
       do k = 1,pver
          frcing_col(:ncol) = frcing_col(:ncol) + frcing(:ncol,k,n)*(zint(:ncol,k)-zint(:ncol,k+1))*km_to_cm
       enddo
       xfcname = trim(forcings(m)%species)//'_CLXF'
       call outfld( xfcname, frcing_col(:ncol), ncol, lchnk )

       ! output plume heights and environment
       call outfld( 'plume_height_EM', plume_height_EM, ncol, lchnk )
       call outfld('zmidr_ph', zmidr(:ncol,:), ncol, lchnk) 
       call outfld('pmid_ph', pmid(:ncol,:), ncol, lchnk) 
       call outfld('tfld_ph', tfld(:ncol,:), ncol, lchnk) 
       call outfld('relhum_ph', relhum(:ncol,:), ncol, lchnk) 
       call outfld('qh2o_ph', qh2o(:ncol,:), ncol, lchnk)
       call outfld('ufld_ph', ufld(:ncol,:), ncol, lchnk)
       call outfld('vfld_ph', vfld(:ncol,:), ncol, lchnk) 
        
       
    end do src_loop

  end subroutine extfrc_set

! subroutines for plumerise
  subroutine cal_plume_height( plume_height,zmidr_v, pmid_v, tfld_v, relhum_v, qh2o_v, ufld_v, vfld_v,lat,lon,tl,pt_v )
    use smk_plumerise, only : smk_pr_driver  
    !use time_manager,  only: get_curr_date
    implicit none
    ! plume-rise parameters
    real(r8), intent(out)  ::   plume_height
    real(r8), intent(in)  ::   zmidr_v(pver)             ! midpoint geopot height - elevation ( km )
    real(r8), intent(in)  ::   pmid_v(pver)            ! midpoint pressure (Pa)
    real(r8), intent(in)  ::   tfld_v(pver)            ! midpoint temperature (K)
    real(r8), intent(in)  ::   relhum_v(pver)           ! relative humidity (0~1)
    real(r8), intent(in)  ::   qh2o_v(pver)            ! specific humidity (kg/kg)
    real(r8), intent(in)  ::   ufld_v(pver)            ! zonal velocity (m/s)
    real(r8), intent(in)  ::   vfld_v(pver)            ! meridional velocity (m/s)
    ! local variables
    real(r8)  :: env(8, pver) ! meterology profiles for this column 
    real(r8)  :: gfed_area, frp  ! fire parameters
    real(r8)  :: lat,lon !
    real(r8)  :: pt_v(pver)  ! potential temperature
    integer :: i,ihr,imn,iyear,imo,iday_m,tod 
    real(r8) :: frp_peak,frp_h,frp_b,frp_sigma,tl
   ! get plume height
   ! env: geopotential height, pressure, temp(state%t), relative humidity(state%),
   ! env: potential T, specific humidity, U, V

    !call smk_pr_driver(plume_height , env, gfed_area, frp, lat )
    ! for fire at each column
    
       call cal_theta(tfld_v(:), pmid_v(:)/100.0_r8, pt_v(:))
       env(1,:) = zmidr_v(pver:1:-1)*1000.0_r8 ! meter
       env(1,:) = env(1,:) - env(1,1) ! set first layer at zero
       env(2,:) = pmid_v(pver:1:-1) 
       env(3,:) = tfld_v(pver:1:-1)
       env(4,:) = relhum_v(pver:1:-1)
       env(5,:) = pt_v(pver:1:-1)
       env(6,:) = qh2o_v(pver:1:-1)
       env(7,:) = ufld_v(pver:1:-1)
       env(8,:) = vfld_v(pver:1:-1)
       plume_height = 1000.0
       gfed_area = 100.0*9.0
       frp = 100.0
       lat = 100.0
       !frp diurnal cycle based on Ke et al., 2021 (WTNA region diurnal cycle)
       !this cycle also similar to WRF-chem fire diurnal cycle used in Kumar et al., 2022
       frp_peak = 155.25_r8 !km/m2 ! 15.525 time 10 as FRP *10 rule
       frp_h = 14.002_r8
       frp_b = 0.023
       frp_sigma = 2.826
       ! local time
       call get_curr_date (iyear,imo,iday_m,tod)  ! year, time of day [sec]
       ihr  = tod/3600
       imn  = mod( tod,3600 )/3600
       if (lon > 180.0_r8) then
          tl = ihr*1.0_r8 + imn*1.0_r8 + (lon-360.0)/15.0_r8 ! behind of UTC
       else
          tl = ihr*1.0_r8 + imn*1.0_r8 + (360.0-lon)/15.0_r8 ! ahead of UTC
       endif 
       if (tl > 24.0) then
          tl = mod( tl,24.0 )
       elseif (tl < 0.0) then
          tl = tl + 24.0
       endif 

       frp=frp_peak*(exp(-0.5*(tl-frp_h)*(tl-frp_h)/frp_sigma/frp_sigma)+frp_b) 
       call smk_pr_driver(plume_height , env, gfed_area, frp, lat )
       plume_height = plume_height*1000.0_r8 ! in meter
       !if(masterproc) write(iulog,*) 'plume_height ', plume_height
  end subroutine cal_plume_height
!----------------------------------------------------------------------------------------
 subroutine cal_theta(temp,pe,theta)
 ! this code is used to calculate the potential temperature
 ! function [theta]=cal_theta(temp, pe)
 ! temp is temperature in K
 ! pe is pressure in mb
 ! temp and pe is array
 implicit none
 integer::i
 real(r8)::P,R,cp,ca1,ca2
 real(r8),intent(in)::temp(pver),pe(pver)
 real(r8),intent(out)::theta(pver)
 P=1000.0 ! reference level pressure 1000 mb
 R=286.9  ! J/(kg*k)
 cp = 1004. ! J/(kg*k)
 ca1 = R/cp
 do i=1,pver
    ca2=(P/pe(i))**ca1
    theta(i)=temp(i)*ca2
 enddo
 end subroutine cal_theta 

end module mo_extfrc
