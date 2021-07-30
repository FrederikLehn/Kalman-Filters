function [x, sol, q_o] = reservoir_simulator(x, G, W, rock, totTime, dt)
%% Single-phase Compressible AD Solver
% The purpose of the example is to give the first introduction to how one
% can use the automatic differentiation (AD) class in MRST to write a flow
% simulator for a compressible single-phase model. For simplicity, the
% reservoir is assumed to be a rectangular box with homogeneous properties
% and no-flow boundaries. Starting from a hydrostatic initial state, the
% reservoir is produced from a horizontal well that will create a zone of
% pressure draw-down. As more fluids are produced, the average pressure in
% the reservoir drops, causing a gradual decay in the production rate.
%
% Suggested reading:
% 
% # K.-A. Lie. An introduction to reservoir simulation using MATLAB: User
% guide for the Matlab Reservoir Simulation Toolbox (MRST). SINTEF ICT,
% December 2015, http://www.sintef.no/Projectweb/MRST/Publications
% # S. Krogstad, K.-A. Lie, O. Møyner, H. M. Nilsen, X. Raynaud, and B.
% Skaflestad. MRST-AD - an open-source framework for rapid prototyping and
% evaluation of reservoir simulation problems. 2015 Reservoir Simulation
% Symposium, Houston, Texas, USA, 23-25 February 2015. DOI: 10.2118/173317-MS
% 

%% Define compressible rock model
% For this problem we use a rock of constant compressibility.  The
% pore-volume is therefore a simple analytic function of fluid pressure.

%Loading updated permeabilities into the rock structure
rock.perm = x(1:length(rock.perm));

cr   = 1e-6/barsa;
p_r  = 200*barsa;
pv_r = poreVolume(G, rock);
pv   = @(p) pv_r .* exp(cr * (p - p_r));

%% Define model for compressible fluid
% the single-phase fluid is assumed to have constant compressibility.  The
% fluid density is therefore a simple analytic function of pressure.
mu    = 5*centi*poise;
c     = 1e-3/barsa;
rho_r = 850*kilogram/meter^3;
rhoS  = 750*kilogram/meter^3;
rho   = @(p) rho_r .* exp(c * (p - p_r));

%% Impose vertical equilibrium
%
% We derive the initial pressure distribution by solving the intial value
% problem
%
% $$ \frac{\mathrm{d}p}{\mathrm{d}z} = g\cdot \rho(p), \quad p(z_0) = p_r. $$
%
% To integrate this equation, we use the built-in |ode23| solver. Notice
% also that the convention is MRST is that the z-direction points
% *downward* and hence the z-component of the gravity vector is *positive*.
gravity reset on, g = norm(gravity);
[z_0, z_max] = deal(0, max(G.cells.centroids(:,3)));
equil  = ode23(@(z,p) g .* rho(p), [z_0, z_max], p_r);
p_init = reshape(deval(equil, G.cells.centroids(:,3)), [], 1);  clear equil

%% Compute transmissibilities on interior connections
%
% We define the transmissibilities as the harmonic average of one-sided
% transmissibilities computed from cell properties (vector from cell
% centroid to face centroid, face areas, and cell permeabilities).
N  = double(G.faces.neighbors);
intInx = all(N ~= 0, 2);
N  = N(intInx, :);                            % Interior neighbors
hT = computeTrans(G, rock);                   % Half-transmissibilities
cf = G.cells.faces(:,1);                      % Map: cell -> face number
nf = G.faces.num;                             % Number of faces
T  = 1 ./ accumarray(cf, 1 ./ hT, [nf, 1]);   % Harmonic average
T  = T(intInx);                               % Restricted to interior

%% Define discrete operators
%
% We use MATLAB(R)'s built-in sparse matrix type to form discrete gradient
% and divergence operators on the grid's interior connections and active
% cells, respectively.  The discrete gradient operator maps from cell pairs
% to faces and is defined as the difference in the cell values on opposite
% sides of the face. The discrete divergence operator is a linear mapping
% from faces to cells and can be computed as the adjoint of the discrete
% gradient operator. The divergence operator represent the sum of all
% outgoing fluxes from a cell. We furthermore create an operator that
% computes averages on the interior connections from cell values in the
% connecting cells.  This operator is used to define fluid densities on the
% model's connections.
n = size(N, 1);
C = sparse(repmat((1 : n).', [2, 1]), N, ...
           repmat([-1, 1], [n, 1]), n, G.cells.num);
grad = @(x) C * x;
div  = @(x)-C' * x;
avg  = @(x) 0.5 * (x(N(:,1)) + x(N(:,2)));

%%
% The discrete operators, together with the transmissibility T and the
% vector pv of pore volumes, represent all the information we need from the
% geological model to discretize the flow equations using a first-order
% finite-volume method. In principle, we could therefore have deleted the
% |G| and |rock| objects. However, the common practice in MRST is to keep
% these objects throughout the simulation. The grid will, for instance, be
% needed for plotting purposes.

%% Define flow equations
% The flow equations are discretized in time by the backward Euler method
% and in space using a finite-volume method. To solve the equations, we
% will write the equations on residual form, F(x) = 0, and use a standard
% Newton-Raphson method to solve the resulting system of nonlinear
% equations. To define F(x), we introduce a number of anonymous functions
% that each define one part of the flow equations. We start by defining the
% anonymous functions for Darcy's law (called flux) and for the continuity
% equation (called presEq).
gradz  = grad(G.cells.centroids(:,3));
flux   = @(p)  -(T / mu).*(grad(p) - g*avg(rho(p)).*gradz);
presEq = @(p,p0,dt) (1 / dt) * (pv(p).*rho(p) - pv(p0).*rho(p0)) ...
                      + div(avg(rho(p)) .* flux(p));

%% Define well equations
% The well is describe by four equations:
% 
% * p_conn describes the hydrostatic pressure distribution inside the
%   wellbore and relates the connection pressure to the bottom-hole
%   pressure
% * q_conn implements the Peaceman well model that relates flow rates to
%   difference between the connection pressure and the reservoir pressure
% * rateEq implements the rate equation, which equates the surface rate to
%   the sum of the flow rates of the individual connections
% * ctrlEq implements the well control, which in our case says that the
%   bottom-hole pressure is to be held constant
wc = W(1).cells; % connection grid cells
WI = W(1).WI;    % well-indices
dz = W(1).dZ;    % connection depth relative to bottom-hole

p_conn  = @(bhp)  bhp + g*dz.*rho(bhp); %connection pressures
q_conn  = @(p,bhp) WI .* (rho(p(wc)) / mu) .* (p_conn(bhp) - p(wc));

rateEq = @(p,bhp,qS)  qS - sum(q_conn(p, bhp))/rhoS;
ctrlEq = @(bhp)       bhp - 100*barsa;

%% Initialize for solution loop
% By nesting and evaluating all the anonymous functions defined above in
% all cells of the reservoir, we can evaluate the residual F(x). The well
% equations are accounted for by evaluating the equations that depend on
% reservoir pressure are evaluated in all cells containing a well
% perforation. However, to *solve* the problem F(x)=0 and find the unknown
% x, we need to compute the gradient dF/dx. To this end, we will use
% automatic differentiation (AD), which is a technique for numerical
% evaluating the derivatives of a function specified by a computer program.
% Using this technique, all we have to do is implement the equations (as we
% did above), declar the input variables as automatic differentiation
% variables, and when our any are evaluated, we get both the residual value
% and the derivatives with respect the the AD variables.

% Initialize primary unknowns as AD variables and keep track of their
% respective indices in the overall vector of unknowns
[p_ad, bhp_ad, qS_ad] = initVariablesADI(p_init, p_init(wc(1)), 0);
nc = G.cells.num;
[pIx, bhpIx, qSIx] = deal(1:nc, nc+1, nc+2);

% Parameters specifying the simulation
numSteps = fix(totTime/dt);                  % number of time-steps
% totTime  = 365*day;             % total simulation time
% dt       = totTime / numSteps;  % constant time step
tol      = 1e-3;                % Newton tolerance
maxits   = 10;                  % max number of Newton its

% Empty structure for keeping the solution
sol = repmat(struct('time', [], 'pressure', [], 'bhp', [], 'qS', []), ...
             [numSteps + 1, 1]);

% Initial state
sol(1)  = struct('time', 0, 'pressure', double(p_ad), ...
                 'bhp', double(bhp_ad), 'qS', double(qS_ad));

%% Main loop
t = 0; step = 0;
while t < totTime,
   t = t + dt;
   step = step + 1;
%    fprintf('\nTime step %d: Time %.2f -> %.2f days\n', ...
%            step, convertTo(t - dt, day), convertTo(t, day));

   % Newton loop
   converged = false;
   p0  = double(p_ad); % Previous step pressure
   nit = 0;
   while ~converged && (nit < maxits),
      % Add source terms to homogeneous pressure equation:
      eq1     = presEq(p_ad, p0, dt);
      eq1(wc) = eq1(wc) - q_conn(p_ad, bhp_ad);

      % Collect all equations
      eqs = {eq1, rateEq(p_ad, bhp_ad, qS_ad), ctrlEq(bhp_ad)};

      % Concatenate equations and solve for update. Concatenating the
      % equations will assemble the Jacobians associated with each
      % subequation into a block-structured Jacobian matrix for the full
      % system
      eq  = cat(eqs{:});
      J   = eq.jac{1};  % Jacobian
      res = eq.val;     % residual
      upd = -(J \ res); % Newton update

      % Update variables
      p_ad.val   = p_ad.val   + upd(pIx);
      bhp_ad.val = bhp_ad.val + upd(bhpIx);
      qS_ad.val  = qS_ad.val  + upd(qSIx);
        
      residual  = norm(res);
      converged = ~(residual > tol);
      nit       = nit + 1;
      %fprintf('  Iteration %3d:  Res = %.4e\n', nit, residual);
   end

   if ~ converged,
      error('Newton solves did not converge')
   else % store solution
      sol(step+1)  = struct('time', t, 'pressure', double(p_ad), ...
                            'bhp', double(bhp_ad), 'qS', double(qS_ad));
   end
end

%% creating output vector
q_o = convertTo(-[sol(2:end).qS], meter^3/day);
x = [rock.perm; sol(end).pressure; ones(G.cells.num,1); q_o(end)];
end

