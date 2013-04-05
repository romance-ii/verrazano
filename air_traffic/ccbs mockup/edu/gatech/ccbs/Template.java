package edu.gatech.ccbs;

import java.util.*;

public class Template {
	public ArrayList values;
	
	public Template() {
		values = new ArrayList();
	}
	
	public void substituteVariables(Pattern pat) {
		Iterator myItr = values.iterator();
		Iterator itsItr = pat.match.variables.iterator();
		
		while(myItr.hasNext() && itsItr.hasNext()) {
			Pattern.Variable myVar = (Pattern.Variable)myItr.next();
			Pattern.Variable itsVar = (Pattern.Variable)itsItr.next();
			myVar.name = itsVar.name;
		}
	}
	
	public Pattern.Variable lookupVariable(String name) {
		Iterator itr = values.iterator();
		
		while(itr.hasNext()) {
			Pattern.Variable var = (Pattern.Variable)itr.next();
			
			if(var.name.equals(name)) {
				return var;
			}
		}
		
		return null;
	}
	
	public String describe() {
		StringBuffer sb = new StringBuffer();
		Pattern.Variable var = lookupVariable("clearance");
		Pattern.Variable aircraft = lookupVariable("aircraft");
		if(var != null && aircraft != null) {
			sb.append((String)var.value);
			AircraftModel am = (AircraftModel)aircraft.value;
			sb.append(" to ");
			sb.append(am.name);
			sb.append("\n");
			
			return sb.toString();
		}
		
		return "Indescribeable!";
	}
	
	public String serializeTemplate(Pattern pat) {
		StringBuffer sb = new StringBuffer();
		Iterator itr = pat.convert.operands.iterator();
		
		System.out.println(pat.convert.commandName);
		sb.append("Clearance -> ");
		sb.append(pat.convert.commandName);
		sb.append("\n");
		
		while(itr.hasNext()) {
			String name = (String)itr.next();
			Pattern.Variable var = lookupVariable(name);
			
			if(var != null) {
				if(var.type == Pattern.VariableType.Path) {
					PathModel pm = (PathModel)var.value;
					Iterator nitr = pm.intersections.iterator();
					while(nitr.hasNext()) {
						Intersection is = (Intersection)nitr.next();
						System.out.println(is.index);
						sb.append("Proceed to ");
						sb.append(is.stringify());
						sb.append("\n");
					}
				}
				else if(var.type == Pattern.VariableType.WaypointID) {
					Intersection is = (Intersection)var.value;
					System.out.println(is.index);
					sb.append(" at ");
					sb.append(is.stringify());
				}
				else if(var.type == Pattern.VariableType.AircraftID ||
						var.type == Pattern.VariableType.RampID ||
						var.type == Pattern.VariableType.RunwayID ||
						var.type == Pattern.VariableType.TaxiwayID) {
					Model m = (Model)var.value;
					System.out.println(m.name);
					sb.append(m.stringify());
					sb.append("\n");
				}
			}
			else {
				System.out.print("Reference to unbound variable: ");
				System.out.print(name);
			}
		}
		
		return sb.toString();
	}
}
